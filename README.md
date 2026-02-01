# ⚡ zproxy

A high-performance, event-driven network proxy core written in **Zig**, designed to replicate and modernize the architectural principles of [**HAProxy**](https://www.haproxy.org/).

## 🚀 What does it work for?

To build a modern, safe, and ultra-high-performance production level load balancer core by leveraging Zig's features while strictly adhering to the zero-copy and non-blocking philosophy of HAProxy.

## ✨ Key Features

### 1. High-Performance Scheduler

- **Elastic Binary Tree (EBTree)**: Implemented a specialized BST with **O(1) duplicate handling** for timers.
  - Unlike standard Red-Black trees or Heaps, this structure avoids O(log N) overhead when processing multiple tasks scheduled for the same expiration time.
- **Pluggable Architecture**: The scheduler is generic and supports switching between `EB64Tree` and `Treap` (Randomized Search Tree) implementations.

### 2. Event Loop

- **Poller**: Wraps `kqueue` (macOS/BSD) and `epoll` (Linux) for O(1) event notification.
- **Non-blocking I/O**: Designed for fully asynchronous operation.

### 3. Performance Benchmarks

We achieved **81 Million operations/sec** for task execution on the `Scheduler` benchmark.

```bash
$ zig build run-bench
Running benchmark with 1000000 tasks...
Scheduling took: 497.59 ms (2009698.81 ops/sec)
Execution took: 12.28 ms (81426593.93 ops/sec)
```

## 🛠 Building & Running

**Requirements**

- Zig (latest/master recommended, built with 0.15.2)

**Run the Echo/Test Engine**

```bash
zig build run
```

**Run Performance Benchmarks**

```bash
zig build run-bench
```

## 📂 Architecture

The project follows a modular design inspired by HAProxy:

- `src/core/poller.zig`: Event loop wrapper.
- `src/core/scheduler.zig`: Task management.
- `src/core/ebtree.zig`: Optimized timer data structure.
- `src/core/memory.zig`: Memory pool management (Planned).

See [Architecture Analysis](zig_haproxy_architecture.md) for detailed design notes.

## 📜 License

MIT
