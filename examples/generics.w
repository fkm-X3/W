// Generic function (monomorphized at compile time)
fn first[T](list: Slice[T]) -> T {
    return list[0]
}

// Generic struct
struct Pair[A, B] {
    first: A
    second: B

    fn swap(self: *Pair[A, B]) -> Pair[B, A] {
        return Pair[B, A]{ .first = self.second, .second = self.first }
    }
}

// Generic enum
enum Option[T] {
    Some(T)
    None
}

fn main() -> i32 {
    let p: Pair[i32, f64] = Pair{ .first = 1, .second = 2.0 }
    let swapped := p.swap()
    return 0
}
