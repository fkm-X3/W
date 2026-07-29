// Match on integer values
fn classify(x: i32) -> String {
    match x {
        0 => "zero",
        1 => "one",
        2 => "two",
        // default fallthrough
        _ => "many",
    }
}

// Match on enum variants
fn describe(result: Result[i32, String]) -> String {
    match result {
        Ok(v) => "got value: " + v,
        Err(e) => "error: " + e,
    }
}

// Match as expression
fn value_or_default(opt: Option[i32]) -> i32 {
    return match opt {
        Some(v) => v,
        None => -1,
    }
}

fn main() -> String {
    return classify(1)
}
