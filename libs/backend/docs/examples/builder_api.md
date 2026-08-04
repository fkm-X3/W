# Tungsten Builder API Examples

The Builder API provides a convenient way to construct IR programmatically.

## Basic Usage Pattern

```zig
const std = @import("std");
const ir = @import("ir");

pub fn main() !void {
    var module = ir.Module.empty;
    defer module.deinit(std.heap.page_allocator);

    var builder = ir.Builder.init(std.heap.page_allocator, &module);

    // 1. Add types
    const void_type = try builder.addVoidType();
    const i32_type = try builder.addIntType(true, 32);

    // 2. Add function
    const func = try builder.addFunction("main", i32_type);
    builder.setCurrentFunction(func);

    // 3. Add basic blocks
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    // 4. Add instructions
    _ = try builder.buildRet(@enumFromInt(0));

    // 5. Print IR
    try ir.printModule(&module, std.io.getStdOut().writer());
}
```

## Example 1: Simple Return

```zig
const i32_type = try builder.addIntType(true, 32);
const func = try builder.addFunction("main", i32_type);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

// Return constant 42
const forty_two = @as(ir.Value, @enumFromInt(42));
_ = try builder.buildRet(forty_two);
```

**Output:**
```
fn @main() -> i32 {
  bb0:
    ret %42
}
```

## Example 2: Fibonacci Function

```zig
const i32_type = try builder.addIntType(true, 32);

// Create function: fn @fib(i32) -> i32
const fib = try builder.addFunction("fib", i32_type);
builder.setCurrentFunction(fib);

// Block 0: entry
const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

// Parameter %n is Value(0)
const n = @as(ir.Value, @enumFromInt(0));

// %0 = icmp sle %n, 1
const one = @as(ir.Value, @enumFromInt(1));
const cond = try builder.buildIcmp(.icmp_sle, i32_type, n, one);

// Create target blocks
const base = try builder.appendBlock();
const recurse = try builder.appendBlock();

// cond_br %0, bb1, bb2
_ = try builder.buildCondBr(cond, base, recurse);

// Block 1: base case
builder.setCurrentBlock(base);
_ = try builder.buildRet(n);

// Block 2: recursive case
builder.setCurrentBlock(recurse);
// %1 = sub %n, 1
const n_minus_1 = try builder.buildSub(i32_type, n, one);
// %2 = call @fib(%1)
const fib_idx = @as(ir.FunctionIdx, @enumFromInt(0));
const fib_type = try builder.addFunctionType(i32_type, &.{i32_type});
const r1 = try builder.buildCall(fib_idx, fib_type, &.{n_minus_1});

// %3 = sub %n, 2
const two = @as(ir.Value, @enumFromInt(2));
const n_minus_2 = try builder.buildSub(i32_type, n, two);
// %4 = call @fib(%3)
const r2 = try builder.buildCall(fib_idx, fib_type, &.{n_minus_2});

// %5 = add %2, %4
const result = try builder.buildAdd(i32_type, r1, r2);

// ret %5
_ = try builder.buildRet(result);
```

**Output:**
```
fn @fib() -> i32 {
  bb0:
    %0 = icmp sle %0, %1
    cond_br %0, bb1, bb2

  bb1:
    ret %0

  bb2:
    %3 = sub %0, %1
    %4 = call @fn0(%3)
    %5 = sub %0, %2
    %6 = call @fn0(%5)
    %7 = add %4, %6
    ret %7
}
```

## Example 3: Arithmetic Operations

```zig
const i32_type = try builder.addIntType(true, 32);
const func = try builder.addFunction("compute", i32_type);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

// Parameters: %a = Value(0), %b = Value(1)
const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));

// %2 = add %a, %b
const sum = try builder.buildAdd(i32_type, a, b);

// %3 = mul %2, %a
const product = try builder.buildMul(i32_type, sum, a);

// %4 = sub %3, %b
const diff = try builder.buildSub(i32_type, product, b);

// %5 = sdiv %4, %a
const quotient = try builder.buildSDiv(i32_type, diff, a);

// ret %5
_ = try builder.buildRet(quotient);
```

**Output:**
```
fn @compute() -> i32 {
  bb0:
    %2 = add %0, %1
    %3 = mul %2, %0
    %4 = sub %3, %1
    %5 = sdiv %4, %0
    ret %5
}
```

## Example 4: Bitwise Operations

```zig
const i32_type = try builder.addIntType(true, 32);
const func = try builder.addFunction("bitwise", i32_type);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

const x = @as(ir.Value, @enumFromInt(0));
const y = @as(ir.Value, @enumFromInt(1));

// %2 = and %x, %y
const and_result = try builder.buildAnd(i32_type, x, y);

// %3 = or %x, %y
const or_result = try builder.buildOr(i32_type, x, y);

// %4 = xor %x, %y
const xor_result = try builder.buildXor(i32_type, x, y);

// %5 = shl %2, 2
const two = @as(ir.Value, @enumFromInt(2));
const shl_result = try builder.buildShl(i32_type, and_result, two);

// %6 = shr %3, 1
const one = @as(ir.Value, @enumFromInt(1));
const shr_result = try builder.buildShr(i32_type, or_result, one);

// ret %6
_ = try builder.buildRet(shr_result);
```

## Example 5: Memory Operations

```zig
const i32_type = try builder.addIntType(true, 32);
const i32_ptr_type = try builder.addPointerType(i32_type);
const void_type = try builder.addVoidType();

const func = try builder.addFunction("swap", void_type);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

// Parameters: %a = Value(0), %b = Value(1) (both i32*)
const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));

// %2 = load %a
const val_a = try builder.buildLoad(i32_type, a);

// %3 = load %b
const val_b = try builder.buildLoad(i32_type, b);

// store %a, %3
_ = try builder.buildStore(i32_type, a, val_b);

// store %b, %2
_ = try builder.buildStore(i32_type, b, val_a);

// ret void
_ = try builder.buildRet(ir.Value.none);
```

## Example 6: Function Calls

```zig
const i32_type = try builder.addIntType(true, 32);

// First function: @add
const add_func = try builder.addFunction("add", i32_type);
builder.setCurrentFunction(add_func);

const add_entry = try builder.appendBlock();
builder.setCurrentBlock(add_entry);

const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));
const sum = try builder.buildAdd(i32_type, a, b);
_ = try builder.buildRet(sum);

// Second function: @main
const main_func = try builder.addFunction("main", i32_type);
builder.setCurrentFunction(main_func);

const main_entry = try builder.appendBlock();
builder.setCurrentBlock(main_entry);

// Call @add(1, 2)
const one = @as(ir.Value, @enumFromInt(1));
const two = @as(ir.Value, @enumFromInt(2));
const add_idx = @as(ir.FunctionIdx, @enumFromInt(0));
const add_type = try builder.addFunctionType(i32_type, &.{ i32_type, i32_type });
const result1 = try builder.buildCall(add_idx, add_type, &.{ one, two });

// Call @add(result1, 3)
const three = @as(ir.Value, @enumFromInt(3));
const result2 = try builder.buildCall(add_idx, add_type, &.{ result1, three });

_ = try builder.buildRet(result2);
```

## Example 7: Phi Nodes (SSA)

```zig
const i32_type = try builder.addIntType(true, 32);
const func = try builder.addFunction("max", i32_type);
builder.setCurrentFunction(func);

const entry = try builder.appendBlock();
builder.setCurrentBlock(entry);

const a = @as(ir.Value, @enumFromInt(0));
const b = @as(ir.Value, @enumFromInt(1));

// if (a > b) goto bb1 else goto bb2
const cond = try builder.buildIcmp(.icmp_sgt, i32_type, a, b);
const bb1 = try builder.appendBlock();
const bb2 = try builder.appendBlock();
_ = try builder.buildCondBr(cond, bb1, bb2);

// bb1: return a
builder.setCurrentBlock(bb1);
_ = try builder.buildRet(a);

// bb2: return b
builder.setCurrentBlock(bb2);
_ = try builder.buildRet(b);
```

## Type Builder Helpers

```zig
// Void type
const void_type = try builder.addVoidType();

// Boolean type
const bool_type = try builder.addBoolType();

// Signed 32-bit integer
const i32_type = try builder.addIntType(true, 32);

// Unsigned 8-bit integer
const u8_type = try builder.addIntType(false, 8);

// 32-bit float
const f32_type = try builder.addFloatType(.f32);

// 64-bit float
const f64_type = try builder.addFloatType(.f64);

// Pointer to i32
const i32_ptr = try builder.addPointerType(i32_type);

// Function type: fn(i32, i32) -> i32
const fn_type = try builder.addFunctionType(i32_type, &.{ i32_type, i32_type });
```

## Complete Example: Full Program

```zig
const std = @import("std");
const ir = @import("ir");

pub fn main() !void {
    var module = ir.Module.empty;
    defer module.deinit(std.heap.page_allocator);

    var builder = ir.Builder.init(std.heap.page_allocator, &module);

    // Types
    const void_type = try builder.addVoidType();
    const i32_type = try builder.addIntType(true, 32);

    // Function: @fib(i32) -> i32
    const fib = try builder.addFunction("fib", i32_type);
    builder.setCurrentFunction(fib);

    // Entry block
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);

    const n = @as(ir.Value, @enumFromInt(0));
    const one = @as(ir.Value, @enumFromInt(1));
    const cond = try builder.buildIcmp(.icmp_sle, i32_type, n, one);

    const base = try builder.appendBlock();
    const recurse = try builder.appendBlock();
    _ = try builder.buildCondBr(cond, base, recurse);

    // Base case
    builder.setCurrentBlock(base);
    _ = try builder.buildRet(n);

    // Recursive case
    builder.setCurrentBlock(recurse);
    const n1 = try builder.buildSub(i32_type, n, one);

    const fib_idx = @as(ir.FunctionIdx, @enumFromInt(0));
    const fib_type = try builder.addFunctionType(i32_type, &.{i32_type});
    const r1 = try builder.buildCall(fib_idx, fib_type, &.{n1});

    const two = @as(ir.Value, @enumFromInt(2));
    const n2 = try builder.buildSub(i32_type, n, two);
    const r2 = try builder.buildCall(fib_idx, fib_type, &.{n2});

    const result = try builder.buildAdd(i32_type, r1, r2);
    _ = try builder.buildRet(result);

    // Print the IR
    try ir.printModule(&module, std.io.getStdOut().writer());
}
```

**Output:**
```
fn @fib() -> i32 {
  bb0:
    %0 = icmp sle %0, %1
    cond_br %0, bb1, bb2

  bb1:
    ret %0

  bb2:
    %3 = sub %0, %1
    %4 = call @fn0(%3)
    %5 = sub %0, %2
    %6 = call @fn0(%5)
    %7 = add %4, %6
    ret %7
}
```
