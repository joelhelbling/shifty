[![Gem Version](https://badge.fury.io/rb/shifty.svg)](https://badge.fury.io/rb/shifty)
[![Build Status](https://travis-ci.org/joelhelbling/shifty.png)](https://travis-ci.org/joelhelbling/shifty)
[![Maintainability](https://api.codeclimate.com/v1/badges/950ded888350c1124348/maintainability)](https://codeclimate.com/github/joelhelbling/shifty/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/950ded888350c1124348/test_coverage)](https://codeclimate.com/github/joelhelbling/shifty/test_coverage)

# The Shifty Framework

_"How many Ruby fibers does it take to screw in a lightbulb?"_

## Quick Start

Add this line to your application's Gemfile:

```ruby
gem 'shifty'
```

And then execute:

    $ bundle

Or install it yourself:

    $ gem install shifty

And then use it:

```ruby
require 'shifty'
```

## Shifty DSL

The DSL provides convenient shorthand for several common types of
workers.  Let's look at them.

But first, be sure to include the DSL mixin:

```ruby
include Shifty::DSL
```

### Source Worker

At the headwater of every Shifty pipeline, there is a source worker
which is able to generate its own work items.

Here is possibly the simplest of source workers, which provides the same
string each time it is invoked:

```ruby
worker = source_worker { "Number 9" }

worker.shift #=> "Number 9"
worker.shift #=> "Number 9"
worker.shift #=> "Number 9"
# ...ad nauseum...
```

Sometimes you want a worker which generates until it doesn't:

```ruby
counter = 0
worker = source_worker do
  if counter < 3
    counter += 1
    counter + 1000
  end
end

worker.shift #=> 1001
worker.shift #=> 1002
worker.shift #=> 1003
worker.shift #=> nil
worker.shift #=> nil (and will be nil henceforth)
```

If all you want is a source worker which generates a series of numbers
the DSL provides an easier way to do it:

```ruby
w1 = source_worker [0,1,2]
w2 = source_worker (0..2)

w1.shift == w2.shift #=> 0
w1.shift == w2.shift #=> 1
w1.shift == w2.shift #=> 2
w1.shift == w2.shift #=> nil (and henceforth, etc.)
```

### Relay Worker

This is perhaps the most "normal" kind of worker in Shifty.  It
accepts a value and returns some transformation of that value:

```ruby
squarer = relay_worker do |number|
  number ** 2
end
```

Of course a relay worker needs a source from which to get values upon
which to operate:

```ruby
source = source_worker (0..3)

squarer.supply = source
```

Or, if you prefer, the DSL provides a vertical pipe for linking the
workers together into a pipeline:

```ruby
pipeline = source | squarer

pipeline.shift #=> 0
pipeline.shift #=> 1
pipeline.shift #=> 4
pipeline.shift #=> 9
pipeline.shift #=> nil
```

### Side Worker

As we travel down the pipeline, from time to time, we will want to
stop and smell the roses, or write to a log file, or drop a beat, or
create some other kind of side-effect.  That's the purpose of the
`side_worker`.  A side worker will pass through the same value that
it received, but as it does so, it can perform some kind side-effect
work.

```
source = source_worker (0..3)

evens = []
even_stasher = side_effect do |value|
  if value % 2 == 0
    evens << value
  end
end

# re-using "squarer" from above example...
pipeline = source | even_stasher | squarer

pipeline.shift #=> 0
pipeline.shift #=> 1
pipeline.shift #=> 4
pipeline.shift #=> 9
pipeline.shift #=> nil

evens #=> [0, 2]
```

Notice that the output is the same as the previous example, even though
we put this `even_stasher` `side_worker` in the middle of the pipeline.

However, we can also see that the `evens` array now contains the even numbers from `source` (the side effect).

_But wait,_ you want to say, _can't we still create side effects with
regular ole relay workers?_  Why, yes.  Yes you can.  Ruby being what
it is, there really isn't a way to prevent the implementation of any
worker from creating side effects.

_And still wait,_ you'll also be wanting to say, _isn't it possible
that a side worker could mutate the value as it's passed through?_  And
again, yes.  It would be very difficult\* in the Ruby language (where
so many things are passed by reference) to perfectly prevent a side
worker from mutating the value.  But please don't.

The side effect worker's purpose is to provide _intentionality_ and
clarity.  When you're creating a side effect, let it be very clear.
And don't do regular, pure functional style work in the same worker.

This will make side effects easier to troubleshoot; if you pull them
out of the pipeline, the pipeline's output shouldn't change.  By the
same token, if there is a problem with a side effect, troubleshooting
it will be much simpler if the side effects are already isolated and
named.

Another measure for preventing side workers from creating unwanted
side-effects is to use `:hardened` mode.  That's right, `side_worker`
has a mode (which defaults to `:normal`).  When set to `:hardened`,
each value is `Marshal.dump`ed and `Marshal.load`ed before being
passed to the side worker's callable.  This helps to ensure that
the original value will be passed through to the next worker in the
queue in a pristine state (unmodified), and that no future or
subsequent modification can take place.

Given a source...

```ruby
source = source_worker [[:foo], [:bar]]
```

Consider this unsafe, unhardened side worker:

```ruby
unsafe = side_worker { |v| v << :boo }
```

This produces unwanted mutations, because of the `<<`.

```ruby
pipeline = source | unsafe

pipeline.shift #=> [:foo, :boo] <-- Oh noes!
pipeline.shift #=> [:bar, :boo] <-- Disaster!
pipeline.shift #=> nil
```

Let's harden it:

```ruby
unsafe = side_worker(:hardened) { |v| v << :boo }
```

The `:hardened` side worker doesn't have access to the original
value, and therefore its shenanigans are moot with respect to
the main workflow:

```ruby
pipeline = source | unsafe

pipeline.shift #=> [:foo] <-- No changes
pipeline.shift #=> [:bar] <-- Much better
pipeline.shift #=> nil
```

### Filter Worker

The filter worker simply passes through the values which are given
to it, but _only_ those values which result in truthiness when your
provided callable is run against it.  Values which result in
falsiness are simply discarded.

```ruby
source = source_worker (0..5)

filter = filter_worker do |value|
  value % 2 == 0
end

pipeline = source | filter

pipeline.shift #=> 0
pipeline.shift #=> 2
pipeline.shift #=> 4
pipeline.shift #=> nil
```

### Batch Worker

The batch worker gathers outputs into batches and the returns each
batch as its output.

```ruby
source = source_worker (0..7)

batch = batch_worker gathering: 3

pipeline = source | batch

pipeline.shift #=> [0, 1, 2]
pipeline.shift #=> [3, 4, 5]
pipeline.shift #=> [6, 7]
pipeline.shift #=> nil
```

Notice how the final batch doesn't have full compliment of three.

Fixed-numbered batch workers are useful for things like pagination,
perhaps, but sometimes we don't want a batch to include a specific
number of items, but to batch together all items until a certain
condition is met.  So batch worker can also accept a callable:

```ruby
source = source_worker [
  "some", "rain", "must\n", "fall", "but", "ok" ]

line_reader = batch_worker do |value|
  value.end_with? "\n"
end

pipeline = source | line_reader

pipeline.shift #=> ["some", "rain", "must\n"]
pipeline.shift #=> ["fall", "but", "ok"]
pipeline.shift #=> nil
```

### Splitter Worker

The splitter worker accepts a value from its supply, and generates an array
and then successively returns each element of the array.  Once the array
has been expended, the splitter worker appeals to its supplier for another
value and the process repeats.

```ruby
source = source_worker [
  'A bold', 'move westward' ]

splitter = splitter_worker do |value|
  value.split(' ')
end

pipeline = source | splitter

pipeline.shift #=> 'A'
pipeline.shift #=> 'bold'
pipeline.shift #=> 'move'
pipeline.shift #=> 'westward'
pipeline.shift #=> nil
```

### Trailing Worker


The trailing worker accepts a value, and returns an array containing the
last _n_ values.  This worker could be useful for things like rolling averages.

No values are returned until n values had been accumulated. New values are
_unshifted_ into the zero-th position in the array of trailing values, so
that a given value will graduate through the array until it reaches the last
position and then subsequently removed.

Maybe it's easiest to just give an example:

```ruby
source = source_worker (0..5)
trailer = trailing_worker 4

pipeline = source | trailer

pipeline.shift #=> [3,2,1,0]
pipeline.shift #=> [4,3,2,1]
pipeline.shift #=> [5,4,3,2]
pipeline.shift #=> nil
```

Note that as soon as a nil is received from the supplying queue, the trailing
worker simply provides a nil.


## Origins of Shifty

Shifty was [Stepladder](https://github.com/joelhelbling/stepladder), which grew out of experimentation with Ruby fibers, after reading
[Dave Thomas' demo of Ruby fibers](http://pragdave.me/blog/2007/12/30/pipelines-using-fibers-in-ruby-19/),
wherein he created a pipeline of fiber processes, emulating the style and syntax of the
\*nix command line.  I noticed that, courtesy of fibers' extremely low surface area,
fiber-to-fiber collaborators could operate with extremely low coupling.  That was the
original motivation for creating the framework.

After playing around with the new framework a bit, I began to notice
other interesting characteristics of this paradigm.

### Escalator vs Elevator

Suppose we are performing several operations on the members of a largish
collection. If we daisy-chain enumerable operators together (which is so
easy and fun with Ruby) we will notice that if something goes awry with
item number two during operation number seven, we nonetheless had to wait
through a complete run of all items through operations 1 - 6 before we
receive the bad news early in operation seven.  Imagine if the first six
operations take a long time to each complete?  Furthermore, what if the
operations on all incomplete items must be reversed in some way (e.g.
cleaned up or rolled back)?  It would be far less messy and far more
expedient if each item could be processed though all operations before
the next one is begun.

This is the design paradigm which shifty makes easy.  Although all
the workers in your assembly line can be coded in the same context (which
is one of the big selling points of the daisy-chaining of enumerable
methods,incidentally), you also get the advantage of passing each item
though the entire op-chain before starting the next.

### Think Locally, Act Globally

Because shifty workers use fibers as their basic API, the are almost
unaware of the outside world.  And they can pretty much be written as such.
At the heart of each Shifty worker is a task which you provide, which
is a callable ruby object (such as a Proc or a lambda).

The scope of the work is whatever scope existed in the task when you
initially created the worker.  And if you want a worker to maintain its
own internal state, you can simply include a loop within the worker's
task, and use the `#handoff` method to pass along the worker's product at
the appropriate point in the loop.

For example:

```ruby
realestate_maker = Shifty::Worker.new do
  oceans = %w[Atlantic Pacific Indiana Arctic]
  previous_ocean = "Atlantic"
  while current_ocean = oceans.sample
    drain current_ocean  #=> let's posit that this is a long-running async process!
    handoff previous_ocean
    previous_ocean = current_ocean
  end
```

Anything scoped to the outside of that loop but inside the worker's task
will essentially become that worker's initial state.  This means we often
don't need to bother with instance variables, accessors, and other
features of classes which deal with maintaining instances' state.

### The Wormhole Effect

Despite the fact that the work is done in separate threads, the _scope_
of the work is the scope of the coordinating body of code.  This means
that even the remaining coupling in such systems --which is primarily
just _common objects_ coupling-- this little remaining coupling is
mitigated by the possibility of having coupled code _live together_.
I call this feature the _folded collaborators_ effect.

Consider the following ~~code~~ vaporware:

```ruby
SUBJECT = 'kitteh'

include Shifty::DSL

tweet_getter = source_worker do
  twitter_api.fetch_my_tweets
end

about_me = filter_worker do |tweet|
  tweet.referenced.include? SUBJECT
end

tweet_formatter = relay_worker do |tweet|
  apply_format_to tweet
end

kitteh_tweets = tweet_getter | about_me | tweet_formatter

while tweet = kitteh_tweets.shift
  display(tweet)
end
```

None of these tasks have hard coupling with each other.  If we were to
insert another worker between the filter and the formatter, neither of
those workers would need changes in their code, assuming the inserted
worker plays nicely with the objects they're all passing along.

Which brings me to the point: these workers to have a dependency upon the
objects they're handing off and receiving.  But we have the capability to
coordinate those workers in a centralized location (such as in this code
example).

## Shifty::Worker

The Shifty::Worker documentation (which was the old README) is now
[here](docs/shifty/worker.md).

## Roadmap

