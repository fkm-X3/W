// Generic enum (sum type)
enum Option[T] {
    Some(T)
    None
}

enum Result[T, E] {
    Ok(T)
    Err(E)
}

fn divide(a: i32, b: i32) -> Result[i32, String] {
    if b == 0 {
        return Err("division by zero")
    }
    return Ok(a / b)
}

fn check() -> i32 {
    let res := divide(10, 2)
    match res {
        Ok(v) => v,
        Err(e) => 0,
    }
}
