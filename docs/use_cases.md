# Shifty Framework: Use Cases

## Introduction

Shifty is a Ruby framework designed for building data processing pipelines. It utilizes a system of cooperatively multitasking "workers" that operate in a single thread. Each worker performs a specific task and can pass data to the next worker in a chain, allowing for the creation of complex data flows in a manageable and sequential manner.

## When to Use Shifty?

Shifty is well-suited for a variety of scenarios where data needs to be processed in a step-by-step fashion. Consider using Shifty for:

*   **Building Data Processing Pipelines:** When your task can be broken down into a series of sequential steps, where each step transforms or enriches the data. Shifty allows you to encapsulate each step within a dedicated worker.
*   **ETL-like Workflows:** For scenarios that involve extracting data from a source, transforming it according to certain rules, and then loading it elsewhere. While Shifty is primarily focused on the in-application transformation aspects, it can be a valuable part of a larger ETL process within a Ruby application.
*   **Cooperative Multitasking Scenarios:** When you have multiple tasks that can effectively "take turns" executing. This is particularly useful if tasks involve waiting for non-blocking operations (though the current version of Shifty operates synchronously) or involve complex stateful interactions that are simpler to manage cooperatively rather than with preemptive threading.
*   **Simplifying Complex Sequential Logic:** If you have a long, monolithic process with many stages, Shifty can help by breaking it down into a chain of smaller, focused, and more understandable workers. This improves modularity and maintainability.
*   **Creating Reusable Components:** Shifty encourages the design of workers that perform specific, well-defined tasks. These workers can then be reused and recombined in different pipelines for various purposes, promoting code reuse.

## Example Scenarios

Here are a few conceptual examples of how Shifty could be applied:

*   **Log Processing:**
    Imagine a pipeline for processing application logs:
    1.  A `FileReaderWorker` reads log lines from a file.
    2.  A `LogParserWorker` parses each line into a structured format (e.g., timestamp, level, message).
    3.  A `ErrorFilterWorker` checks the parsed log data and only passes on entries marked as "ERROR" or "CRITICAL".
    4.  A `ReportFormatterWorker` formats these error entries into a human-readable report.
    5.  A `FileWriterWorker` or `EmailNotifierWorker` outputs the report.

*   **Data Transformation Chain:**
    A simple pipeline demonstrating data manipulation:
    1.  A `NumberSourceWorker` generates a sequence of numbers (e.g., 1, 2, 3, ...).
    2.  A `MultiplierWorker` receives each number and multiplies it by 2.
    3.  A `StringFormatterWorker` converts the multiplied number into a string, perhaps adding a prefix (e.g., "RESULT: 4").
    4.  A `ConsoleOutputWorker` prints the final formatted string to the console.

*   **Batch Processing:**
    Accumulating data into batches before further processing:
    1.  An `ItemStreamWorker` produces individual items (e.g., from a database query or an incoming data stream).
    2.  A `BatchWorker` (Shifty provides a `batch_worker` for this purpose) accumulates these items. It passes the accumulated batch to the next worker once a certain number of items are collected or a timeout occurs.
    3.  A `BatchProcessorWorker` then processes the entire batch of items at once (e.g., bulk database insert, writing to a file).

## A Note on Values Passed Between Workers

The examples above pass data from one worker to the next. Because Shifty runs
each value through every worker before starting the next value, workers must
treat a handed-off value as read-only and express changes as new values
(`arr + [x]`, `hash.merge(...)`, `value.with(...)`) rather than mutating in
place (`arr <<`, `hash[k] =`, `map!`). As of 0.6.0 this is enforced: values
are deeply frozen at every handoff by default, and a task that mutates its
input raises `Shifty::PolicyViolation` at the offending worker. Workers that
genuinely need a private scratch copy can declare `policy: :isolated`; workers
that need a shared mutable reference can declare `policy: :shared`. See the
wiki's [Handoff Policies](https://github.com/joelhelbling/shifty/wiki/Handoff-Policies)
and [Coding Idioms Under :frozen](https://github.com/joelhelbling/shifty/wiki/Coding-Idioms-Under-Frozen)
pages, and the [Migration Guide](https://github.com/joelhelbling/shifty/wiki/Migration-Guide-0.6).

## Conclusion

Shifty aims to provide an intuitive and straightforward way to construct data processing systems within Ruby applications. By breaking down complex tasks into manageable, cooperatively multitasking workers, it helps in building modular, maintainable, and easy-to-understand data pipelines.
