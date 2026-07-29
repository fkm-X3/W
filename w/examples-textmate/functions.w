// Standard function with explicit types
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// Single-expression shorthand (body = expr, no braces)
fn double(x: i32) -> i32 = x * 2

// No return type = void
fn greet() {
    let msg := "hello"
}

// Calling functions
fn main() -> i32 {
    return add(1, double(2))
}
