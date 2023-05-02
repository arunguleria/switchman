# frozen_string_literal: true

require "spec_helper"

module Switchman
  module ActiveRecord
    describe FinderMethods do
      include RSpecHelper

      before do
        @user = @shard1.activate { User.create! }
      end

      describe "#find_one" do
        it "finds with a global id" do
          expect(User.find(@user.global_id)).to eq @user
        end

        it "finds with a global id and a current scope" do
          User.where("id > 0").scoping do
            # having a current scope skips the statement cache in rails 4.2
            expect(User.find(@user.global_id)).to eq @user
          end
        end

        it "is able to find by global id with qualified names" do
          other_user = User.create!
          # make sure we're not caching a statement from the wrong shard
          expect(User.find(other_user.id)).to eq other_user

          expect(User.find(@user.global_id)).to eq @user
        end

        it "finds digit with a global id on an association" do
          appendage = @shard2.activate { Appendage.create!(user: @user) }
          digit = appendage.digits.create!
          @user.associated_shards = [@shard1, @shard2]
          expect(@user.digits.find(digit.global_id)).to eq digit
        end

        it "doesn't break non-integral primary keys" do
          pv = PageView.create!(request_id: "abc")
          expect(PageView.shard(Shard.default).find("abc")).to eq pv
        end

        it "doesn't break with bogus id" do
          expect { User.shard(Shard.default).find("bogus") }.to raise_error(::ActiveRecord::RecordNotFound)
        end
      end

      describe "#find_last" do
        it "works across shards with qualified names" do
          @shard1.activate do
            User.create!
            @user = User.create!
          end
          expect(User.shard(@shard1).last).to eq @user
        end
      end

      describe "#find_by_attributes" do
        it "finds with a global id" do
          expect(User.find_by_id(@user.global_id)).to eq @user
        end

        it "finds with an array of global ids" do
          expect(User.find_by_id([@user.global_id])).to eq @user
        end
      end

      describe "#find_some" do
        it "finds multiple objects by global id" do
          user = User.create!
          user2 = @shard2.activate { User.create! }
          expect(User.find([user.global_id, user2.global_id]).sort_by(&:id)).to eq [user, user2].sort_by(&:id)
        end
      end

      describe "#find_or_initialize" do
        it "initializes with the shard from the scope" do
          @user.destroy
          u = User.shard(@shard1).where(id: @user).first_or_initialize
          expect(u).to be_new_record
          expect(u.shard).to eq @shard1
        end
      end

      describe "#exists?" do
        it "works for an out-of-shard scope" do
          scope = @shard1.activate { User.where(id: @user) }
          expect(scope.shard_value).to eq @shard1
          expect(scope.exists?).to be true
        end

        it "works for a multi-shard scope" do
          @shard2.activate { User.create!(name: "multi-shard exists") }
          expect(User.where(name: "multi-shard exists").shard(Shard.all).exists?).to be true
        end

        it "works for a multi-shard association scope" do
          @user = User.create!
          @shard1.activate { Appendage.create!(user_id: @user.id) }
          expect(@user.appendages.shard([Shard.default, @shard1]).exists?).to be true
        end

        it "works if a condition is passed" do
          expect(User.exists?(@user.global_id)).to be true
        end

        it "works with binds in joined associations" do
          @user = User.create!
          a1 = @user.appendages.create!(type: "Arm")
          a2 = @user.appendages.create!
          expect(User.joins(:arms).where("appendages.id" => a1.id).exists?).to be true
          expect(User.joins(:arms).where("appendages.id" => a2.id).exists?).to be false
        end
      end
    end
  end
end
