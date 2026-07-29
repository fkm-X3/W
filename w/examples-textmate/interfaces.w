// Interface = structural contract (like Python duck typing, checked at compile time)
// No `implements` keyword — satisfaction is structural
interface Speakable {
    fn speak(self: *Self) -> String
}

interface Indexable[T] {
    fn get(self: *Self, index: i64) -> T
}

interface Addable[T] {
    fn add(self: *Self, other: *T) -> T
}

// Types automatically satisfy interfaces by having matching signatures
struct Person {
    name: String

    fn init(name: String) -> Person {
        return Person{ .name = name }
    }
}

impl Person {
    fn speak(self: *Person) -> String {
        return "Hi, I'm " + self.name
    }
}

// *impl Interface = fat pointer for dynamic dispatch
fn greet(entity: *impl Speakable) -> String {
    return "says: " + entity.speak()
}

fn main() -> String {
    let p := Person.init("Alice")
    return greet(&p)
}
