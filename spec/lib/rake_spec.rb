# frozen_string_literal: true

require "spec_helper"

Dummy::Application.load_tasks

module Switchman
  describe Rake do
    include RSpecHelper

    describe ".shard_scope" do
      before do
        @s1, @s2, @s3 = [Shard.default, @shard1, @shard2].sort
      end

      def shard_scope(shard_ids)
        Rake.send(:shard_scope, Shard.all, shard_ids).order(:id)
      end

      it "works for default shard" do
        expect(shard_scope("default").to_a).to eq [Shard.default]
      end

      it "excludes default shard" do
        scope = shard_scope("-default")
        # the query is negative
        expect(scope.to_sql).to be_include(Shard.default.id.to_s)
        shards = scope.to_a
        expect(shards).not_to be_empty
        expect(shards).not_to be_include(Shard.default)
      end

      it "no-ops exclude the default shard" do
        scope = shard_scope("default,-default")
        expect(scope.to_a).to be_empty
      end

      it "works for a half-open range" do
        expect(shard_scope("#{@s1.id}...#{@s2.id}").to_a).to eq [@s1]
      end

      it "works for a half-closed range" do
        expect(shard_scope("#{@s1.id}..#{@s2.id}").order(:id).to_a).to eq [@s1, @s2]
      end

      it "removes from a range" do
        expect(shard_scope("#{@s1.id}..#{@s2.id},-#{@s1.id}").to_a).to eq [@s2]
      end

      it "works for multiple ranges" do
        expect(shard_scope("#{@s1.id}...#{@s1.id + 1},#{@s3.id}...#{@s3.id + 1}").order(:id).to_a).to eq [@s1, @s3]
      end

      it "works for beginning infinite range" do
        expect(shard_scope("..#{@s2.id}").order(:id).to_a).to eq [@s1, @s2]
      end

      it "works for ending infinite range" do
        expect(shard_scope("#{@s2.id}..").order(:id).to_a).to eq [@s2, @s3]
      end

      it "defaults include all if you're only excluding" do
        scope = shard_scope("-#{@s1.id}").to_a
        expect(scope.length).to eq(Shard.count - 1)
        expect(scope).not_to be_include(@s1)
      end

      it "does not forget about ranges when specific ids cancel out" do
        scope = shard_scope("#{@s1.id},#{@s2.id}..#{@s2.id},-#{@s1.id}").to_a
        expect(scope).to eq [@s2]
      end

      it "supports fractions" do
        s4 = Shard.default.database_server.shards.create!(name: "s4")
        hole = Shard.default.database_server.shards.create!(name: "hole")
        s5 = Shard.default.database_server.shards.create!(name: "s5")
        hole.destroy

        expect(shard_scope("1/3").to_a).to eq [@s1, @s2]
        expect(shard_scope("2/3").to_a).to eq [@s3, s4]
        expect(shard_scope("3/3").to_a).to eq [s5]

        expect(shard_scope("1/7").to_a).to eq [@s1]
        expect(shard_scope("2/7").to_a).to eq [@s2]
        expect(shard_scope("3/7").to_a).to eq [@s3]
        expect(shard_scope("4/7").to_a).to eq [s4]
        expect(shard_scope("5/7").to_a).to eq [s5]
        expect(shard_scope("6/7").to_a).to eq []
        expect(shard_scope("7/7").to_a).to eq []
      end
    end

    describe ".scope" do
      it "supports selecting open servers" do
        db = DatabaseServer.create({ open: true, adapter: "postgresql" })
        shard = db.shards.create!
        expect(Rake.scope(database_server: "open").to_a).to eq([shard])
      end
    end

    describe ".shardify_task" do
      before do
        ::Rake::Task.define_task("dummy:touch_mirror_users") do
          MirrorUser.update_all(updated_at: Time.now.utc)
        end
      end

      after do
        ::Rake::Task.clear
      end

      it "only activates each shard as the for ActiveRecord::Base by default" do
        mu = @shard2.activate(MirrorUniverse) do
          mu = MirrorUser.create!
          MirrorUser.where(id: mu).update_all(updated_at: 2.days.ago)
          mu
        end

        Rake.shardify_task("dummy:touch_mirror_users")

        @shard1.activate(MirrorUniverse) do
          ::Rake::Task["dummy:touch_mirror_users"].execute
        end

        @shard2.activate(MirrorUniverse) do
          expect(mu.reload.updated_at).to be < 1.day.ago
        end
      end

      it "can activate each shard as all classes" do
        mu = @shard2.activate(MirrorUniverse) do
          mu = MirrorUser.create!
          MirrorUser.where(id: mu).update_all(updated_at: 2.days.ago)
          mu
        end

        Rake.shardify_task("dummy:touch_mirror_users", classes: -> { Shard.sharded_models })

        @shard1.activate(MirrorUniverse) do
          ::Rake::Task["dummy:touch_mirror_users"].execute
        end

        @shard2.activate(MirrorUniverse) do
          expect(mu.reload.updated_at).to be > 1.day.ago
        end
      end
    end
  end
end
