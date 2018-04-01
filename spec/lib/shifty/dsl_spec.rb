require 'spec_helper'

module Shifty
  describe DSL do
    include described_class

    describe '#source_worker' do
      context 'normal usage' do
        context 'with an array' do
          Given(:worker) { source_worker [:fee, :fi] }

          Then { worker.shift == :fee }
          And  { worker.shift == :fi }
          And  { worker.shift.nil? }
        end

        context 'with a range' do
          Given(:worker) { source_worker (0..2) }

          Then { worker.shift == 0 }
          And  { worker.shift == 1 }
          And  { worker.shift == 2 }
          And  { worker.shift.nil? }
        end

        context 'with a string' do
          Given(:worker) { source_worker 'abc' }

          Then { worker.shift == 'a' }
          And  { worker.shift == 'b' }
          And  { worker.shift == 'c' }
          And  { worker.shift.nil? }
        end

        context 'with a hash' do
          Given(:worker) { source_worker({foo: 2, bar: 'yarr'}) }

          Then { worker.shift == [:foo, 2] }
          And  { worker.shift == [:bar, 'yarr'] }
          And  { worker.shift.nil? }
        end

        context 'with a anything else' do
          Given(:worker) { source_worker :foo }

          Then { worker.shift == :foo }
          And  { worker.shift.nil? }
        end

        context 'with a callable' do
          Given(:worker) do
            notes = %i[doh ray me fa so la ti]
            source_worker do
              notes.shift if notes.size > 4
            end
          end

          Then { worker.shift == :doh }
          And  { worker.shift == :ray }
          And  { worker.shift == :me }
          And  { worker.shift.nil? }
        end

        context 'with a callable and an argument' do
          Given(:notes) { %i[so la ti] }
          Given(:worker) do
            source_worker notes do |note|
              note.to_s.upcase
            end
          end

          Then { worker.shift == 'SO' }
          And  { worker.shift == 'LA' }
          And  { worker.shift == 'TI' }
          And  { worker.shift.nil? }
        end
      end

      context 'illegal usage' do
        context 'with no argument and arity > 0' do
          Given(:invocation) do
            -> { source_worker { |v| v * 2 } }
          end
          Then { expect(invocation).to raise_error(/arity == 0/) }
        end
      end

      context 'with argument' do
        context 'and arity == 0' do
          Given(:invocation) do
            -> { source_worker([]) { :boo } }
          end
          Then { expect(invocation).to raise_error(/arity == 1/) }
        end
        context 'and arity > 1' do
          Given(:invocation) do
            -> { source_worker([]) { |p, q| :boo } }
          end
          Then { expect(invocation).to raise_error(/arity == 1/) }
        end
      end
    end

    describe '#relay_worker' do
      context 'normal usage' do
        Given(:source) { source_worker %w[better stronger faster] }
        Given(:relay) do
          relay_worker { |v| v.gsub(/t/, '+') }
        end

        When { source | relay }

        Then { relay.shift == 'be++er' }
        And  { relay.shift == 's+ronger' }
        And  { relay.shift == 'fas+er' }
        And  { relay.shift.nil? }
      end

      context 'illegal usage' do
        context 'arity == 0' do
          Given(:invocation) do
            -> { relay_worker() { :foo } }
          end

          Then { expect(invocation).to raise_error(/arity == 1/) }
        end
      end
    end

    describe '#side_worker' do
      context 'normal usage' do
        Given(:source) { source_worker (0..2) }
        Given(:side_effect) { [] }
        Given(:worker) do
          side_effect
          side_worker { |v| side_effect << v * 2 }
        end

        When { source | worker }

        Then { worker.shift == 0 }
        And  { worker.shift == 1 }
        And  { worker.shift == 2 }
        And  { worker.shift.nil? }
        And  { side_effect == [0, 2, 4] }
      end

      context 'mode' do
        Given(:source) { source_worker [[:foo], [:bar]] }
        Given(:unsafe_task) { Proc.new {|v| v << :boo } }

        When { source | worker }

        context ':normal (default)' do
          Given(:worker) do
            side_worker(&unsafe_task)
          end

          Then { worker.shift == [:foo, :boo] }
          And  { worker.shift == [:bar, :boo] }
          And  { worker.shift.nil? }

        end

        context ':hardened' do
          Given(:worker) do
            side_worker :hardened, &unsafe_task
          end

          Then { worker.shift == [:foo] }
          And  { worker.shift == [:bar] }
          And  { worker.shift.nil? }
        end
      end

      context 'illegal usage' do
        context 'arity == 0' do
          Given(:invocation) do
            -> { side_worker() { :foo } }
          end

          Then { expect(invocation).to raise_error(/arity == 1/) }
        end
      end
    end

    describe '#filter_worker' do
      context 'normal usage' do
        Given(:source) { source_worker (1..3) }

        When { source | filter }

        Given(:filter) do
           filter_worker { |v| v % 2 == 0 }
        end

        Then { filter.shift == 2 }
        And { expect(filter.shift).to be_nil }
      end

      context 'illegal usage' do
        context 'requires a callable' do
          context 'with no arguments or block' do
            Given(:invocation) { -> { filter_worker } }
            Then { expect(invocation).to raise_error(/supply a callable/) }
          end

          context 'with no callable' do
            Given(:invocation) { -> { filter_worker :foo } }
            Then { expect(invocation).to raise_error(/supply a callable/) }
          end

          context 'with callable arg' do
            Given(:arg) { Proc.new { true } }
            Given(:invocation) { -> { filter_worker arg } }
            Then { expect(invocation).to_not raise_error }
          end

          context 'with both callable arg and block' do
            Given(:arg) { Proc.new { true } }
            Given(:invocation) { -> { filter_worker(arg) do false; end } }
            Then { expect(invocation).to raise_error(/two callables/) }
          end
        end
      end
    end

    describe '#batch_worker' do
      context 'normal usage' do
        When { source | worker }

        context 'with specified "gathering" batch size' do
          Given(:source) { source_worker (0..7) }
          Given(:worker) do
            batch_worker gathering: 3
          end

          Then { worker.shift == [ 0, 1, 2 ] }
          And  { worker.shift == [ 3, 4, 5 ] }
          And  { worker.shift == [ 6, 7 ] }
          And  { worker.shift.nil? }
        end

        context 'defaults to batch size of 1' do
          Given(:source) { source_worker [8,9] }
          Given(:worker) { batch_worker }

          Then { worker.shift == [ 8 ] }
          And  { worker.shift == [ 9 ] }
          And  { worker.shift.nil? }
        end

        context 'collects until condition' do
          Given(:source) { source_worker (1..5) }
          Given(:worker) do
            batch_worker { |n| n % 2 == 0 }
          end

          Then { worker.shift == [ 1, 2 ] }
          And  { worker.shift == [ 3, 4 ] }
          And  { worker.shift == [ 5 ] }
          And  { worker.shift.nil? }
        end
      end

      context 'illegal usage' do
        context 'requires a callable' do
          context 'with arity == 0' do
            Given(:invocation) { -> { batch_worker() { :foo } } }
            Then { expect(invocation).to raise_error(/arity == 1/) }
          end

          context 'with arity > 1' do
            Given(:invocation) { -> { batch_worker() { |a,b| :foo } } }
            Then { expect(invocation).to raise_error(/arity == 1/) }
          end
        end
      end
    end

    context '#splitter_worker' do
      context 'normal usage' do
        Given(:source) { source_worker ['A bold', 'move northward'] }
        Given(:worker) do
          splitter_worker do |value|
            value.split(' ')
          end
        end

        When { source | worker }

        Then { worker.shift == 'A' }
        And  { worker.shift == 'bold' }
        And  { worker.shift == 'move' }
        And  { worker.shift == 'northward' }
        And  { worker.shift.nil? }
      end

      context 'always returns an array' do
        Given(:source) { source_worker [:foo] }
        Given(:worker) do
          splitter_worker { |value| value }
        end

        When { source | worker }

        Then { worker.shift == :foo }
        And  { worker.shift == nil }
      end

      context 'illegal usage' do
        context 'requires a callable' do
          context 'with arity == 0' do
            Given(:invocation) { -> { splitter_worker() { [] } } }
            Then { expect(invocation).to raise_error(/arity == 1/) }
          end

          context 'with arity > 1' do
            Given(:invocation) { -> { splitter_worker() { |a,b| [] } } }
            Then { expect(invocation).to raise_error(/arity == 1/) }
          end
        end
      end
    end

    context '#trailing_worker' do
      context 'normal usage' do
        Given(:source) { source_worker (0..5) }
        Given(:worker) { trailing_worker 4 }

        When { source | worker }

        Then { worker.shift == [3,2,1,0] }
        And  { worker.shift == [4,3,2,1] }
        And  { worker.shift == [5,4,3,2] }
        And  { worker.shift.nil? }
      end

      context 'default trail size' do
        Given(:source) { source_worker (0..3) }
        Given(:worker) { trailing_worker }

        When { source | worker }

        Then { worker.shift == [1,0] }
        And  { worker.shift == [2,1] }
        And  { worker.shift == [3,2] }
        And  { worker.shift.nil? }
      end
    end

  end
end
