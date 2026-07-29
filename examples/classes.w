class Animal {
    name: String

    fn init(name: String) -> Animal {
        return Animal{ .name = name }
    }

    fn speak(self: *Animal) -> String {
        return "..."
    }

    prop name_len: i32 {
        get => self.name.len()
    }
}

// Inheritance: class Name(Parent)
class Dog(Animal) {
    breed: String

    fn init(name: String, breed: String) -> Dog {
        let base := Animal.init(name)
        return Dog{ .name = base.name, .breed = breed }
    }

    // Override (explicit — no accidental overrides)
    override fn speak(self: *Dog) -> String {
        return "Woof!"
    }
}

fn main() -> String {
    let d := Dog.init("Rex", "Husky")
    return d.speak()
}
