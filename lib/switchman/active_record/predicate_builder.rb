# frozen_string_literal: true

module Switchman
  module ActiveRecord
    module PredicateBuilder
      def convert_value_to_association_ids(value, primary_key)
        if value.is_a?(::ActiveRecord::Base)
          value.send(primary_key) # needed for sharded id translation
        else
          super
        end
      end

      module PolymorphicArrayValue
        def convert_to_id(value)
          case value
          when ::ActiveRecord::Base
            value.send(primary_key(value))
          else
            super
          end
        end
      end
    end
  end
end
