struct Vec2 {
    x: f64
    y: f64

    // Methods attached via impl block (inside struct)
    // Explicit self parameter
    fn add(self: *Vec2, other: *Vec2) -> Vec2 {
        return Vec2{ .x = self.x + other.x, .y = self.y + other.y }
    }

    fn len(self: *Vec2) -> f64 {
        return (self.x * self.x + self.y * self.y)
    }

    // Associated function (no self)
    fn zero() -> Vec2 {
        return Vec2{ .x = 0.0, .y = 0.0 }
    }
}

fn main() -> f64 {
    let v1: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
    let v2: Vec2 = Vec2{ .x = 3.0, .y = 4.0 }
    let v3 := v1.add(&v2)
    return v3.x
}
