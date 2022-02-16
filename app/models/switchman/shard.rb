# frozen_string_literal: true

require 'switchman/database_server'
require 'switchman/default_shard'
require 'switchman/environment'
require 'switchman/errors'

module Switchman
  class Shard < UnshardedRecord
    # ten trillion possible ids per shard. yup.
    IDS_PER_SHARD = 10_000_000_000_000

    # only allow one default
    validates_uniqueness_of :default, if: ->(s) { s.default? }

    after_save :clear_cache
    after_destroy :clear_cache

    scope :primary, -> { where(name: nil).order(:database_server_id, :id).distinct_on(:database_server_id) }

    class << self
      def sharded_models
        @sharded_models ||= [::ActiveRecord::Base, UnshardedRecord].freeze
      end

      def default(reload: false, with_fallback: false)
        if !@default || reload
          # Have to create a dummy object so that several key methods still work
          # (it's easier to do this in one place here, and just assume that sharding
          # is up and running everywhere else).  This includes for looking up the
          # default shard itself. This also needs to be a local so that this method
          # can be re-entrant
          default = DefaultShard.instance

          # if we already have a default shard in place, and the caller wants
          # to use it as a fallback, use that instead of the dummy instance
          default = @default if with_fallback && @default

          # the first time we need a dummy dummy for re-entrancy to avoid looping on ourselves
          @default ||= default

          # Now find the actual record, if it exists
          @default = begin
            find_cached('default_shard') { Shard.where(default: true).take } || default
          # If we are *super* early in boot, the connection pool won't exist; we don't want to fill in the default shard yet
          rescue ::ActiveRecord::ConnectionNotEstablished
            nil
          # rescue the fake default if the table doesn't exist
          rescue
            default
          end
          return default unless @default

          # make sure this is not erroneously cached
          @default.database_server.remove_instance_variable(:@primary_shard) if @default.database_server.instance_variable_defined?(:@primary_shard)

          # and finally, check for cached references to the default shard on the existing connection
          sharded_models.each do |klass|
            klass.connection.shard = @default if klass.connected? && klass.connection.shard.default?
          end
        end
        @default
      end

      def current(klass = ::ActiveRecord::Base)
        klass ||= ::ActiveRecord::Base
        klass.current_switchman_shard
      end

      def activate(shards)
        activated_classes = activate!(shards)
        yield
      ensure
        activated_classes&.each do |klass|
          klass.connected_to_stack.pop
        end
      end

      def activate!(shards)
        activated_classes = nil
        shards.each do |klass, shard|
          next if klass == UnshardedRecord

          next unless klass.current_shard != shard.database_server.id.to_sym ||
                      klass.current_switchman_shard != shard

          (activated_classes ||= []) << klass
          klass.connected_to_stack << { shard: shard.database_server.id.to_sym, klasses: [klass], switchman_shard: shard }
        end
        activated_classes
      end

      def active_shards
        sharded_models.map do |klass|
          [klass, current(klass)]
        end.compact.to_h
      end

      def lookup(id)
        id_i = id.to_i
        return current if id_i == current.id || id == 'self'
        return default if id_i == default.id || id.nil? || id == 'default'

        id = id_i
        raise ArgumentError if id.zero?

        unless cached_shards.key?(id)
          cached_shards[id] = Shard.default.activate do
            find_cached(['shard', id]) { find_by(id: id) }
          end
        end
        cached_shards[id]
      end

      def preload_cache
        cached_shards.reverse_merge!(active_shards.values.index_by(&:id))
        cached_shards.reverse_merge!(all.index_by(&:id))
      end

      def clear_cache
        cached_shards.clear
      end

      # ==== Parameters
      #
      # * +shards+ - an array or relation of Shards to iterate over
      # * +classes+ - an array of classes to activate
      #    parallel: - true/false to execute in parallel, or an integer of how many
      #                sub-processes. Note that parallel invocation currently uses
      #                forking, so should be used sparingly because you cannot get
      #                results back
      #    exception: - :ignore, :raise, :defer (wait until the end and raise the first
      #                error), or a proc
      def with_each_shard(*args, parallel: false, exception: :raise, &block)
        raise ArgumentError, "wrong number of arguments (#{args.length} for 0...2)" if args.length > 2

        return Array.wrap(yield) unless default.is_a?(Shard)

        if args.length == 1
          if Array === args.first && args.first.first.is_a?(Class)
            classes = args.first
          else
            scope = args.first
          end
        else
          scope, classes = args
        end

        parallel = [Environment.cpu_count || 2, 2].min if parallel == true
        parallel = 0 if parallel == false || parallel.nil?

        scope ||= Shard.all
        scope = scope.order(::Arel.sql('database_server_id IS NOT NULL, database_server_id, id')) if ::ActiveRecord::Relation === scope && scope.order_values.empty?

        if parallel > 1
          if ::ActiveRecord::Relation === scope
            # still need a post-uniq, cause the default database server could be NULL or Rails.env in the db
            database_servers = scope.reorder('database_server_id').select(:database_server_id).distinct.
                               map(&:database_server).compact.uniq
            # nothing to do
            return if database_servers.count.zero?

            scopes = database_servers.to_h do |server|
              [server, server.shards.merge(scope)]
            end
          else
            scopes = scope.group_by(&:database_server)
          end

          exception_pipes = []
          pids = []
          out_fds = []
          err_fds = []
          pid_to_name_map = {}
          fd_to_name_map = {}
          errors = []

          wait_for_output = lambda do
            ready, = IO.select(out_fds + err_fds)
            ready.each do |fd|
              if fd.eof?
                fd.close
                out_fds.delete(fd)
                err_fds.delete(fd)
                next
              end
              line = fd.readline
              puts "#{fd_to_name_map[fd]}: #{line}"
            end
          end

          # only one process; don't bother forking
          return with_each_shard(scopes.first.last, classes, exception: exception, &block) if scopes.length == 1

          # clear connections prior to forking (no more queries will be executed in the parent,
          # and we want them gone so that we don't accidentally use them post-fork doing something
          # silly like dealloc'ing prepared statements)
          ::ActiveRecord::Base.clear_all_connections!

          scopes.each do |server, subscope|
            name = server.id

            exception_pipe = IO.pipe
            exception_pipes << exception_pipe
            pid, io_in, io_out, io_err = Open4.pfork4(lambda do
              Switchman.config[:on_fork_proc]&.call

              # set a pretty name for the process title, up to 128 characters
              # (we don't actually know the limit, depending on how the process
              # was started)
              # first, simplify the binary name by stripping directories,
              # then truncate arguments as necessary
              bin = File.basename($0) # Process.argv0 doesn't work on Ruby 2.5 (https://bugs.ruby-lang.org/issues/15887)
              max_length = 128 - bin.length - name.length - 3
              args = ARGV.join(' ')
              args = args[0..max_length] if max_length >= 0
              new_title = [bin, args, name].join(' ')
              Process.setproctitle(new_title)

              with_each_shard(subscope, classes, exception: exception, &block)
              exception_pipe.last.close
            rescue Exception => e # rubocop:disable Lint/RescueException
              begin
                dumped = Marshal.dump(e)
                dumped = nil if dumped.length > 64 * 1024
              rescue
                dumped = nil
              end

              if dumped.nil?
                # couldn't dump the exception; create a copy with just
                # the message and the backtrace
                e2 = e.class.new(e.message)
                backtrace = e.backtrace
                # truncate excessively long backtraces
                backtrace = backtrace[0...25] + ['...'] + backtrace[-25..] if backtrace.length > 50
                e2.set_backtrace(backtrace)
                e2.instance_variable_set(:@active_shards, e.instance_variable_get(:@active_shards))
                dumped = Marshal.dump(e2)
              end
              exception_pipe.last.set_encoding(dumped.encoding)
              exception_pipe.last.write(dumped)
              exception_pipe.last.flush
              exception_pipe.last.close
              exit! 1
            end)
            exception_pipe.last.close
            pids << pid
            io_in.close # don't care about writing to stdin
            out_fds << io_out
            err_fds << io_err
            pid_to_name_map[pid] = name
            fd_to_name_map[io_out] = name
            fd_to_name_map[io_err] = name

            while pids.count >= parallel
              while out_fds.count >= parallel
                # wait for output if we've hit the parallel limit
                wait_for_output.call
              end
              # we've gotten all the output from one fd so wait for its child process to exit
              found_pid, status = Process.wait2
              pids.delete(found_pid)
              errors << pid_to_name_map[found_pid] if status.exitstatus != 0
            end
            # we've gotten all the output from one fd so wait for its child process to exit
            found_pid, status = Process.wait2
            pids.delete(found_pid)
            errors << pid_to_name_map[found_pid] if status.exitstatus != 0
          end

          wait_for_output.call while out_fds.any? || err_fds.any?
          pids.each do |pid|
            _, status = Process.waitpid2(pid)
            errors << pid_to_name_map[pid] if status.exitstatus != 0
          end

          # check for an exception; we only re-raise the first one
          exception_pipes.each do |exception_pipe|
            serialized_exception = exception_pipe.first.read
            next if serialized_exception.empty?

            ex = Marshal.load(serialized_exception) # rubocop:disable Security/MarshalLoad
            raise ex
          ensure
            exception_pipe.first.close
          end

          unless errors.empty?
            raise ParallelShardExecError,
                  "The following subprocesses did not exit cleanly: #{errors.sort.join(', ')}"
          end

          return
        end

        classes ||= []

        previous_shard = nil
        result = []
        ex = nil
        scope.each do |shard|
          # shard references a database server that isn't configured in this environment
          next unless shard.database_server

          shard.activate(*classes) do
            result.concat Array.wrap(yield)
          rescue
            case exception
            when :ignore
              # ignore
            when :defer
              ex ||= $!
            when Proc
              exception.call
            # when :raise
            else
              raise
            end
          end
          previous_shard = shard
        end
        raise ex if ex

        result
      end

      def partition_by_shard(array, partition_proc = nil)
        shard_arrays = {}
        array.each do |object|
          partition_object = partition_proc ? partition_proc.call(object) : object
          case partition_object
          when Shard
            shard = partition_object
          when ::ActiveRecord::Base
            if partition_object.respond_to?(:associated_shards)
              partition_object.associated_shards.each do |a_shard|
                shard_arrays[a_shard] ||= []
                shard_arrays[a_shard] << object
              end
              next
            else
              shard = partition_object.shard
            end
          when Integer, /^\d+$/, /^(\d+)~(\d+)$/
            local_id, shard = Shard.local_id_for(partition_object)
            local_id ||= partition_object
            object = local_id unless partition_proc
          end
          shard ||= Shard.current
          shard_arrays[shard] ||= []
          shard_arrays[shard] << object
        end
        # TODO: use with_each_shard (or vice versa) to get
        # connection management and parallelism benefits
        shard_arrays.inject([]) do |results, (shard, objects)|
          results.concat(shard.activate { Array.wrap(yield objects) })
        end
      end

      # it's tedious to hold onto this same
      # kind of sign state and transform the
      # result in multiple places, so
      # here we can operate on the absolute value
      # in a provided block and trust the sign will
      # stay as provided.  This assumes no consumer
      # will return a nil value from the block.
      def signed_id_operation(input_id)
        sign = input_id.negative? ? -1 : 1
        output = yield input_id.abs
        output * sign
      end

      # converts an AR object, integral id, string id, or string short-global-id to a
      # integral id. nil if it can't be interpreted
      def integral_id_for(any_id)
        case any_id
        when ::Arel::Nodes::Casted
          any_id = any_id.value
        when ::Arel::Nodes::BindParam
          any_id = any_id.value.value_before_type_cast
        end

        case any_id
        when ::ActiveRecord::Base
          any_id.id
        when /^(\d+)~(-?\d+)$/
          local_id = $2.to_i
          signed_id_operation(local_id) do |id|
            return nil if id > IDS_PER_SHARD

            ($1.to_i * IDS_PER_SHARD) + id
          end
        when Integer, /^-?\d+$/
          any_id.to_i
        end
      end

      # takes an id-ish, and returns a local id and the shard it's
      # local to. [nil, nil] if it can't be interpreted. [id, nil]
      # if it's already a local ID. [nil, nil] if it's a well formed
      # id, but the shard it refers to does not exist
      NIL_NIL_ID = [nil, nil].freeze
      def local_id_for(any_id)
        id = integral_id_for(any_id)
        return NIL_NIL_ID unless id

        return_shard = nil
        local_id = signed_id_operation(id) do |abs_id|
          if abs_id < IDS_PER_SHARD
            abs_id
          elsif (return_shard = lookup(abs_id / IDS_PER_SHARD))
            abs_id % IDS_PER_SHARD
          else
            return NIL_NIL_ID
          end
        end
        [local_id, return_shard]
      end

      # takes an id-ish, and returns an integral id relative to
      # target_shard. returns nil if it can't be interpreted,
      # or the integral version of the id if it refers to a shard
      # that does not exist
      def relative_id_for(any_id, source_shard, target_shard)
        integral_id = integral_id_for(any_id)
        local_id, shard = local_id_for(integral_id)
        return integral_id unless local_id

        shard ||= source_shard
        return local_id if shard == target_shard

        shard.global_id_for(local_id)
      end

      # takes an id-ish, and returns a shortened global
      # string id if global, and itself if local.
      # returns any_id itself if it can't be interpreted
      def short_id_for(any_id)
        local_id, shard = local_id_for(any_id)
        return any_id unless local_id
        return local_id unless shard

        "#{shard.id}~#{local_id}"
      end

      # takes an id-ish, and returns an integral global id.
      # returns nil if it can't be interpreted
      def global_id_for(any_id, source_shard = nil)
        id = integral_id_for(any_id)
        return any_id unless id

        signed_id_operation(id) do |abs_id|
          if abs_id >= IDS_PER_SHARD
            abs_id
          else
            source_shard ||= Shard.current
            source_shard.global_id_for(abs_id)
          end
        end
      end

      def shard_for(any_id, source_shard = nil)
        return any_id.shard if any_id.is_a?(::ActiveRecord::Base)

        _, shard = local_id_for(any_id)
        shard || source_shard || Shard.current
      end

      private

      def add_sharded_model(klass)
        @sharded_models = (sharded_models + [klass]).freeze
        initialize_sharding
      end

      def initialize_sharding
        full_connects_to_hash = DatabaseServer.all.to_h { |db| [db.id.to_sym, db.connects_to_hash] }
        sharded_models.each do |klass|
          connects_to_hash = full_connects_to_hash.deep_dup
          if klass == UnshardedRecord
            # no need to mention other databases for the unsharded category
            connects_to_hash = { ::Rails.env.to_sym => DatabaseServer.find(nil).connects_to_hash }
          end

          # prune things we're already connected to
          if klass.connection_specification_name == klass.name
            connects_to_hash.each do |(db_name, role_hash)|
              role_hash.each_key do |role|
                role_hash.delete(role) if klass.connection_handler.retrieve_connection_pool(
                  klass.connection_specification_name, role: role, shard: db_name
                )
              end
            end
          end

          klass.connects_to shards: connects_to_hash
        end
      end

      # in-process caching
      def cached_shards
        @cached_shards ||= {}.compare_by_identity
      end

      def add_to_cache(shard)
        cached_shards[shard.id] = shard
      end

      def remove_from_cache(shard)
        cached_shards.delete(shard.id)
      end

      def find_cached(key)
        # can't simply cache the AR object since Shard has a custom serializer
        # that calls this method
        attributes = Switchman.cache.fetch(key) { yield&.attributes }
        return nil unless attributes

        shard = Shard.new
        attributes.each do |attr, value|
          shard.send(:"#{attr}=", value) if shard.respond_to?(:"#{attr}=")
        end
        shard.clear_changes_information
        shard.instance_variable_set(:@new_record, false)
        # connection info doesn't exist in database.yml;
        # pretend the shard doesn't exist either
        shard = nil unless shard.database_server
        shard
      end
    end

    def name
      unless instance_variable_defined?(:@name)
        # protect against re-entrancy
        @name = nil
        @name = read_attribute(:name) || default_name
      end
      @name
    end

    def name=(name)
      write_attribute(:name, @name = name)
      remove_instance_variable(:@name) if name.nil?
    end

    def database_server
      @database_server ||= DatabaseServer.find(database_server_id)
    end

    def database_server=(database_server)
      self.database_server_id = database_server.id
      @database_server = database_server
    end

    def primary?
      self == database_server.primary_shard
    end

    def description
      [database_server.id, name].compact.join(':')
    end

    # Shards are always on the default shard
    def shard
      Shard.default
    end

    def original_id
      id
    end

    def activate(*classes, &block)
      shards = hashify_classes(classes)
      Shard.activate(shards, &block)
    end

    # for use from console ONLY
    def activate!(*classes)
      shards = hashify_classes(classes)
      Shard.activate!(shards)
      nil
    end

    # custom serialization, since shard is self-referential
    def _dump(_depth)
      id.to_s
    end

    def self._load(str)
      lookup(str.to_i)
    end

    def drop_database
      raise('Cannot drop the database of the default shard') if default?
      return unless read_attribute(:name)

      begin
        adapter = database_server.config[:adapter]
        sharding_config = Switchman.config || {}
        drop_statement = sharding_config[adapter]&.[](:drop_statement)
        drop_statement ||= sharding_config[:drop_statement]
        if drop_statement
          drop_statement = Array(drop_statement).dup.
                           map { |statement| statement.gsub('%{name}', name) }
        end

        case adapter
        when 'mysql', 'mysql2'
          activate do
            ::GuardRail.activate(:deploy) do
              drop_statement ||= "DROP DATABASE #{name}"
              Array(drop_statement).each do |stmt|
                ::ActiveRecord::Base.connection.execute(stmt)
              end
            end
          end
        when 'postgresql'
          activate do
            ::GuardRail.activate(:deploy) do
              # Shut up, Postgres!
              conn = ::ActiveRecord::Base.connection
              old_proc = conn.raw_connection.set_notice_processor {}
              begin
                drop_statement ||= "DROP SCHEMA #{name} CASCADE"
                Array(drop_statement).each do |stmt|
                  ::ActiveRecord::Base.connection.execute(stmt)
                end
              ensure
                conn.raw_connection.set_notice_processor(&old_proc) if old_proc
              end
            end
          end
        end
      rescue
        logger.info "Drop failed: #{$!}"
      end
    end

    # takes an id local to this shard, and returns a global id
    def global_id_for(local_id)
      return nil unless local_id

      self.class.signed_id_operation(local_id) do |abs_id|
        abs_id + (id * IDS_PER_SHARD)
      end
    end

    # skip global_id.hash
    def hash
      id.hash
    end

    def destroy
      raise('Cannot destroy the default shard') if default?

      super
    end

    private

    def clear_cache
      Shard.default.activate do
        Switchman.cache.delete(['shard', id].join('/'))
        Switchman.cache.delete('default_shard') if default?
      end
      self.class.clear_cache
    end

    def default_name
      database_server.shard_name(self)
    end

    def hashify_classes(classes)
      if classes.empty?
        { ::ActiveRecord::Base => self }
      else
        classes.each_with_object({}) do |klass, h|
          h[klass] = self
        end
      end
    end
  end
end
