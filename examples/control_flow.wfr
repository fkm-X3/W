fn abs(x: i32) -> i32 {
    // if/else as expression
    return if x > 0 { x } else { -x }
}

fn sum_to(n: i32) -> i32 {
    mut s: i32 = 0
    while s < n {
        s = s + 1
    }
    return s
}

fn sum_range() -> i32 {
    mut s: i32 = 0
    for i in 0..10 {
        s = s + i
    }
    return s
}

fn defer_demo() -> String {
    let f := acquire()
    defer f.close()
    return f.read_all()
}

fn main() -> i32 {
    return sum_range()
}
