# Tungsten IR In-Memory Layout

Tungsten's IR uses compact, flat data structures for cache efficiency.

## Core Data Structures

### Handles (4 bytes each)

```zig
pub const Value = enum(u32) {        // 4 bytes
    none = 0,
    _,
};

pub const TypeIdx = enum(u32) { _ };      // 4 bytes
pub const InstructionIdx = enum(u32) { _ }; // 4 bytes
pub const BasicBlockIdx = enum(u32) { _ };  // 4 bytes
pub const FunctionIdx = enum(u32) { _ };    // 4 bytes
```

### Instruction (12 bytes)

```zig
pub const Instruction = struct {
    opcode: Opcode,        // 1 byte (enum u8)
    type_idx: TypeIdx,     // 4 bytes
    operands: OperandSlice, // 4 bytes (start: u32, len: u16)
};
// Total: 12 bytes per instruction
```

### OperandSlice (4 bytes)

```zig
pub const OperandSlice = struct {
    start: u32,  // Index into extra_data array
    len: u16,    // Number of operands
};
```

### BasicBlock (8 bytes)

```zig
pub const BasicBlock = struct {
    first_inst: InstructionIdx, // 4 bytes
    inst_count: u32,            // 4 bytes
};
// Total: 8 bytes per basic block
```

## Example: Fibonacci Function Memory Layout

Consider this IR:

```
fn @fib(i32 %n) -> i32 {
  entry:
    %0 = icmp sle %n, 1
    cond_br %0, bb1, bb2

  bb1:
    ret %n

  bb2:
    %1 = sub %n, 1
    %2 = call @fib(%1)
    %3 = sub %n, 2
    %4 = call @fib(%3)
    %5 = add %2, %4
    ret %5
}
```

### Module Structure

```
Module {
  functions: [Function],
  types: [IrType],
  strings: StringPool,
}
```

### Function Layout

```
Function {
  name: StringRef { start: 0, len: 3 },  // "fib"
  return_type: TypeIdx(1),                // i32
  blocks: [BasicBlock],                   // 3 blocks
  instructions: [Instruction],            // 8 instructions
  extra_data: [u32],                      // operand data
}
```

### Basic Blocks Array

| Index | first_inst | inst_count |
|-------|------------|------------|
| 0 (entry) | InstructionIdx(0) | 2 |
| 1 (bb1) | InstructionIdx(2) | 1 |
| 2 (bb2) | InstructionIdx(3) | 5 |

### Instructions Array

| Index | opcode | type_idx | operands |
|-------|--------|----------|----------|
| 0 | `icmp_sle` | i32 | { start: 0, len: 2 } |
| 1 | `cond_br` | void | { start: 2, len: 3 } |
| 2 | `ret` | void | { start: 5, len: 1 } |
| 3 | `sub` | i32 | { start: 6, len: 2 } |
| 4 | `call` | i32 | { start: 8, len: 2 } |
| 5 | `sub` | i32 | { start: 10, len: 2 } |
| 6 | `call` | i32 | { start: 12, len: 2 } |
| 7 | `add` | i32 | { start: 14, len: 2 } |
| 8 | `ret` | void | { start: 16, len: 1 } |

### Extra Data Array (Operand Pool)

| Index | Value | Meaning |
|-------|-------|---------|
| 0 | 0 | lhs: %n (Value(0)) |
| 1 | 1 | rhs: 1 (constant) |
| 2 | 1 | cond: %0 (Value(1)) |
| 3 | 1 | true_block: bb1 |
| 4 | 2 | false_block: bb2 |
| 5 | 0 | ret_val: %n (Value(0)) |
| 6 | 0 | lhs: %n (Value(0)) |
| 7 | 1 | rhs: 1 (constant) |
| 8 | 0 | fn: @fib (FunctionIdx(0)) |
| 9 | 3 | arg: %1 (Value(3)) |
| 10 | 0 | lhs: %n (Value(0)) |
| 11 | 2 | rhs: 2 (constant) |
| 12 | 0 | fn: @fib (FunctionIdx(0)) |
| 13 | 5 | arg: %3 (Value(5)) |
| 14 | 4 | lhs: %2 (Value(4)) |
| 15 | 6 | rhs: %4 (Value(6)) |
| 16 | 7 | ret_val: %5 (Value(7)) |

### Type Table

| Index | Type |
|-------|------|
| 0 | void |
| 1 | i32 (signed: true, bits: 32) |
| 2 | i32* (pointer to i32) |
| 3 | fn(i32) -> i32 (function type) |

### String Pool

| Offset | Content |
|--------|---------|
| 0 | "fib" |

## Memory Comparison: Tungsten vs LLVM

### LLVM IR (Fibonacci)
- Each instruction: ~48-64 bytes (with Use nodes)
- Each basic block: ~128 bytes (with terminator)
- Total for fib: ~800+ bytes

### Tungsten IR (Fibonacci)
- Each instruction: 12 bytes
- Each basic block: 8 bytes
- Total for fib: ~120 bytes (including operand pool)

**Result:** ~6-7x smaller memory footprint

## Builder API Memory Layout

When using the Builder API, memory is allocated incrementally:

```
Builder {
  gpa: Allocator,
  module: *Module,
  current_func: ?FunctionIdx,
  current_block: ?BasicBlockIdx,
}
```

### Construction Flow

1. `addFunction("fib", i32_type)` → appends to `module.functions`
2. `appendBlock()` → appends to `function.blocks`
3. `buildIcmp(...)` → appends to `function.instructions` and `function.extra_data`
4. `buildCondBr(...)` → appends to `function.instructions` and `function.extra_data`

All allocations are contiguous in memory, maximizing cache hits during compilation passes.
