> This page covers the raw `Shifty::Worker` API. The
> [wiki's Worker-Types page](https://github.com/joelhelbling/shifty/wiki/Worker-Types)
> covers every DSL worker and their handoff-policy behavior.

# Shifty::Worker

_The workhorse of the Shifty framework._

## Workers have tasks...

Initialize with a block of code:

```ruby
source_worker = Shifty::Worker.new { "hulk" }

source_worker.shift #=> "hulk"
```
If you supply a worker with another worker as its supply, then you
can give it a task which accepts a value:

```ruby
relay_worker = Shifty::Worker.new { |name| name.upcase }
relay_worker.supply = source_worker

relay_worker.shift #=> "HULK"
```

You can also initialize a worker by passing in a callable object
as its task:

```ruby
capitalizer = Proc.new { |name| name.capitalize }
relay_worker = Shifty::Worker.new(task: capitalizer, supply: source_worker)

relay_worker.shift #=> 'Hulk'
```

A worker's task is fixed at construction — there is no `task=`
accessor. (And as of 0.6.0, `#freeze!` can lock the rest of the
topology down too, so the pipeline you composed is the pipeline
that runs.)

Even workers without a task have a task; all workers actually come
with a default task which simply passes on the received value unchanged:

```ruby
useless_worker = Shifty::Worker.new(supply: source_worker)

useless_worker.shift #=> 'hulk'
```

## The pipeline DSL

You can stitch your workers together using the vertical pipe ("|") like so:

```ruby
pipeline = source_worker | relay_worker | another worker
```

...and then just call on that pipeline (it's actually the last worker in the
chain):

```ruby
while next_value = pipeline.shift do
  do_something_with next_value
  # etc.
end
```

