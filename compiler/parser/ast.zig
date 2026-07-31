const std = @import("std");

pub const StringRef = struct {
    start: u32,
    end: u32,

    pub fn slice(self: StringRef, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const NodeIdx = enum(u32) {
    none = 0,
    _,

    pub fn toInt(self: NodeIdx) u32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(v: u32) NodeIdx {
        return @enumFromInt(v);
    }
};

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_op,
    or_op,
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    range,
};

pub const UnaryOp = enum(u8) {
    neg,
    not,
    bit_not,
    deref,
    ref,
};

pub const NodeList = struct {
    indices: []const NodeIdx,
};

pub const Node = union(enum) {
    // Literals / primaries
    int_literal: i64,
    float_literal: f64,
    string_literal: StringRef,
    char_literal: StringRef,
    bool_literal: bool,
    null_literal,
    identifier: StringRef,

    // Expressions
    binary_op: struct { op: BinaryOp, left: NodeIdx, right: NodeIdx },
    unary_op: struct { op: UnaryOp, operand: NodeIdx },
    call: struct { func: NodeIdx, args: NodeList },
    field_access: struct { object: NodeIdx, field: StringRef },
    index_access: struct { object: NodeIdx, index: NodeIdx },
    paren_expr: NodeIdx,
    struct_init: struct { ty: NodeIdx, fields: NodeList },
    range_expr: struct { start: NodeIdx, end: NodeIdx },

    // Statements
    let_stmt: struct { mutable: bool, name: StringRef, ty: ?NodeIdx, init_expr: ?NodeIdx },
    return_stmt: struct { value: ?NodeIdx },
    expr_stmt: struct { expr: NodeIdx },
    defer_stmt: struct { expr: NodeIdx },

    // Declarations
    fn_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        params: NodeList,
        return_type: ?NodeIdx,
        body: NodeIdx,
        is_override: bool,
    },
    struct_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        fields: NodeList,
        methods: NodeList,
    },
    class_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        parent: ?NodeIdx,
        fields: NodeList,
        methods: NodeList,
    },
    enum_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        variants: NodeList,
    },
    interface_decl: struct {
        name: StringRef,
        generic_params: NodeList,
        methods: NodeList,
    },
    impl_block: struct { self_type: NodeIdx, methods: NodeList },
    prop_decl: struct { name: StringRef, ty: NodeIdx, getter: NodeIdx, setter: ?NodeIdx },
    import_decl: struct { path: NodeList, alias: ?StringRef },

    // Control flow
    if_expr: struct { cond: NodeIdx, then_body: NodeIdx, else_body: ?NodeIdx },
    while_expr: struct { cond: NodeIdx, body: NodeIdx },
    for_range: struct { var_name: StringRef, start: NodeIdx, end: NodeIdx, body: NodeIdx },
    for_each: struct { var_name: StringRef, iterable: NodeIdx, body: NodeIdx },
    match_expr: struct { scrutinee: NodeIdx, arms: NodeList },
    block: struct { stmts: NodeList },

    // Module root
    module: struct { decls: NodeList },

    // Misc
    param: struct { name: StringRef, ty: NodeIdx },
    field: struct { name: StringRef, ty: TypeRepr },
    enum_variant: struct { name: StringRef, fields: NodeList },
    match_arm: struct { pattern: NodeIdx, body: NodeIdx },
    struct_init_field: struct { name: StringRef, value: NodeIdx },
};

pub const TypeRepr = union(enum) {
    plain: NodeIdx,
    pointer: NodeIdx,
    generic_app: struct { base: NodeIdx, args: NodeList },
};

pub const AstArena = struct {
    nodes: std.ArrayListUnmanaged(Node),
    allocator: std.mem.Allocator,
    list_allocs: std.ArrayListUnmanaged([]NodeIdx),

    pub fn init(allocator: std.mem.Allocator) AstArena {
        var arena = AstArena{
            .nodes = .empty,
            .allocator = allocator,
            .list_allocs = .empty,
        };
        arena.nodes.append(allocator, undefined) catch unreachable;
        return arena;
    }

    pub fn deinit(self: *AstArena) void {
        for (self.list_allocs.items) |slice| {
            self.allocator.free(slice);
        }
        self.list_allocs.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
    }

    pub fn append(self: *AstArena, node: Node) !NodeIdx {
        const idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, node);
        return NodeIdx.fromInt(@intCast(idx));
    }

    pub fn get(self: *const AstArena, idx: NodeIdx) *const Node {
        return &self.nodes.items[@as(usize, @intCast(idx.toInt()))];
    }

    pub fn allocNodeList(self: *AstArena, indices: []const NodeIdx) !NodeList {
        const copy = try self.allocator.alloc(NodeIdx, indices.len);
        @memcpy(copy, indices);
        try self.list_allocs.append(self.allocator, copy);
        return .{ .indices = copy };
    }
};
