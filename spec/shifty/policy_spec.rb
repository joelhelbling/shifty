require "spec_helper"

module Shifty
  RSpec.describe Policy do
    describe "global configuration" do
      after { Shifty.reset_configuration! }

      context "out of the box" do
        Then { expect(Shifty.config.default_policy).to eq(:frozen) }
      end

      context "configured with a block" do
        When { Shifty.configure { |c| c.default_policy = :shared } }
        Then { expect(Shifty.config.default_policy).to eq(:shared) }
      end

      context "reset restores the default" do
        Given { Shifty.configure { |c| c.default_policy = :shared } }
        When { Shifty.reset_configuration! }
        Then { expect(Shifty.config.default_policy).to eq(:frozen) }
      end
    end

    describe ".resolve" do
      context "returns a policy for each known name" do
        Then { expect(Policy.resolve(:frozen)).to be Policy::Frozen }
        And { expect(Policy.resolve(:isolated)).to be Policy::Isolated }
        And { expect(Policy.resolve(:shared)).to be Policy::Shared }
      end

      context "rejects an unknown name" do
        Then do
          expect { Policy.resolve(:bogus) }
            .to raise_error(ArgumentError, /unknown policy :bogus/)
        end
      end

      context "maps deprecated :hardened to :isolated with a warning" do
        Given(:warning) do
          capture_stderr { @resolved = Policy.resolve(:hardened) }
        end
        Then { expect(warning).to match(/:hardened is deprecated.*:isolated/m) }
        And { expect(warning).to match(/removed in 1\.0\.0/) }
        And { expect(@resolved).to be Policy::Isolated }
      end
    end
  end
end
