//! AST → Tungsten IR lowering.
//!
//! Walks a type-checked module and drives the Tungsten `api.Context` to build
//! IR: one function per `fn`/method (methods mangled as `TypeName_method`),
//! vtable globals per class, a deduplicated string literal pool, and
//! alloca/malloc/field-offset lowering for structs/classes.
//!
//! Value convention: every W value occupies one 8-byte slot (matching the
//! backend's slot-based codegen). A `String` value is a pointer to a
//! 16-byte `[len][ptr]` block (see `string.zig`); a struct value is a
//! pointer to its stack-allocated block (see `class.zig`); a class value is
//! a pointer to its heap allocation.
//!
//! Known simplifications (see plan.md):
//! - All integer math runs in 64-bit slots; narrow types are not truncated.
//! - Struct copies share the underlying block (no deep copy).
//! - Classes leak: no `free` is emitted for the ref-counted header.
//! - Expression-position `if`/`match` are not lowered (the type checker
//!   currently types them as `void`).

const std = @import("std");
const api = @import("Tungsten").api;
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const types_mod = @import("../semantic/types.zig");
const typecheck_mod = @import("../semantic/typecheck.zig");
const string_mod = @import("string.zig");
const class_mod = @import("class.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;
const TypePool = types_mod.TypePool;
const TypeIdx = types_mod.TypeIdx;
const SemType = types_mod.SemType;

/// One method of a struct/class, plus its already-computed IR return type.
pub const MethodEntry = struct {
    fidx: api.FunctionIdx,
    ret_ir: api.TypeIdx,
};

pub const MethodTable = struct {
    by_name: std.StringHashMapUnmanaged(MethodEntry),
    order: std.ArrayListUnmanaged(api.FunctionIdx),

    fn deinit(self: *MethodTable, gpa: Allocator) void {
        self.by_name.deinit(gpa);
        self.order.deinit(gpa);
    }
};

/// A name binding inside a function body.
/// `value` is the SSA value (parameters) or slot pointer (locals);
/// `ty` is the semantic type, resolved from the checker's cached node types.
const Binding = struct {
    value: api.Value,
    ty: TypeIdx,
};

pub const Lowerer = struct {
    gpa: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    checker: *typecheck_mod.TypeChecker,
    ctx: *api.Context,
    strings: string_mod.LiteralPool,

    void_ty: api.TypeIdx,
    bool_ty: api.TypeIdx,
    i8_ty: api.TypeIdx,
    i16_ty: api.TypeIdx,
    i32_ty: api.TypeIdx,
    i64_ty: api.TypeIdx,
    u8_ty: api.TypeIdx,
    u16_ty: api.TypeIdx,
    u32_ty: api.TypeIdx,
    u64_ty: api.TypeIdx,
    f32_ty: api.TypeIdx,
    f64_ty: api.TypeIdx,
    ptr_ty: api.TypeIdx,

    /// fn_decl node -> created FunctionIdx (module functions and methods).
    fn_by_node: std.AutoHashMapUnmanaged(NodeIdx, api.FunctionIdx),
    /// struct/class decl node -> method table.
    methods: std.AutoHashMapUnmanaged(NodeIdx, MethodTable),
    /// class decl node -> vtable global.
    vtable_by_class: std.AutoHashMapUnmanaged(NodeIdx, api.GlobalIdx),
    /// (fn_decl node, FunctionIdx) pairs in creation order, for body lowering.
    all_functions: std.ArrayListUnmanaged(struct { node: NodeIdx, idx: api.FunctionIdx }),

    /// Function parameters of the current function: name -> binding.
    params: std.StringHashMapUnmanaged(Binding),
    /// Mutable locals of the current function: name -> binding (slot pointer).
    locals: std.StringHashMapUnmanaged(Binding),
    /// Shadowed bindings for scope-aware local binding.
    shadows: std.ArrayListUnmanaged(struct { name: []const u8, prev: ?Binding }),
    /// Deferred expressions, innermost scope last.
    pending_defers: std.ArrayListUnmanaged(NodeIdx),

    block_terminated: bool = false,

    pub fn init(
        gpa: Allocator,
        arena: *AstArena,
        source: []const u8,
        type_pool: *TypePool,
        diagnostics: *diag.Diagnostics,
        checker: *typecheck_mod.TypeChecker,
        ctx: *api.Context,
    ) !Lowerer {
        var self = Lowerer{
            .gpa = gpa,
            .arena = arena,
            .source = source,
            .type_pool = type_pool,
            .diagnostics = diagnostics,
            .checker = checker,
            .ctx = ctx,
            .strings = undefined,
            .void_ty = try ctx.voidType(),
            .bool_ty = try ctx.boolType(),
            .i8_ty = try ctx.intType(true, 8),
            .i16_ty = try ctx.intType(true, 16),
            .i32_ty = try ctx.intType(true, 32),
            .i64_ty = try ctx.intType(true, 64),
            .u8_ty = try ctx.intType(false, 8),
            .u16_ty = try ctx.intType(false, 16),
            .u32_ty = try ctx.intType(false, 32),
            .u64_ty = try ctx.intType(false, 64),
            .f32_ty = try ctx.floatType(.f32),
            .f64_ty = try ctx.floatType(.f64),
            .ptr_ty = undefined,
            .fn_by_node = .empty,
            .methods = .empty,
            .vtable_by_class = .empty,
            .all_functions = .empty,
            .params = .empty,
            .locals = .empty,
            .shadows = .empty,
            .pending_defers = .empty,
        };
        self.ptr_ty = try ctx.ptrType(self.i64_ty);
        self.strings = string_mod.LiteralPool.init(gpa, ctx);
        return self;
    }

    pub fn deinit(self: *Lowerer) void {
        var it = self.methods.valueIterator();
        while (it.next()) |table| {
            table.deinit(self.gpa);
        }
        self.methods.deinit(self.gpa);
        self.fn_by_node.deinit(self.gpa);
        self.vtable_by_class.deinit(self.gpa);
        self.all_functions.deinit(self.gpa);
        self.params.deinit(self.gpa);
        self.locals.deinit(self.gpa);
        self.shadows.deinit(self.gpa);
        self.pending_defers.deinit(self.gpa);
        self.strings.deinit();
    }

    /// Lower the entire checked module into `ctx`.
    pub fn run(self: *Lowerer) !void {
        const module = self.arena.get(self.checker.module_node);

        // Pass 1: create every function and index methods.
        for (module.module.decls.indices) |decl_idx| {
            const decl = self.arena.get(decl_idx);
            switch (decl.*) {
                .fn_decl => |f| {
                    if (f.generic_params.indices.len > 0) {
                        self.codegenError(decl_idx, "generic functions are not lowered yet", .{});
                        continue;
                    }
                    _ = try self.createFunction(decl_idx, self.nameSlice(f.name));
                },
                .struct_decl => |s| try self.collectMethods(decl_idx, self.nameSlice(s.name), s.methods),
                .class_decl => |c| try self.collectMethods(decl_idx, self.nameSlice(c.name), c.methods),
                .impl_block => |ib| try self.collectImplMethods(decl_idx, ib),
                else => {},
            }
        }

        // Pass 2: vtable globals (one per class, even if method-less).
        for (module.module.decls.indices) |decl_idx| {
            const decl = self.arena.get(decl_idx);
            if (decl.* != .class_decl) continue;
            var funcs = std.ArrayList(api.FunctionIdx).empty;
            defer funcs.deinit(self.gpa);
            if (self.methods.get(decl_idx)) |table| {
                try funcs.appendSlice(self.gpa, table.order.items);
            }
            const g = try class_mod.generateVtable(self.gpa, self.ctx, self.nameSlice(decl.class_decl.name), funcs.items);
            try self.vtable_by_class.put(self.gpa, decl_idx, g);
        }

        // Pass 3: function bodies.
        for (self.all_functions.items) |f| {
            try self.lowerFunctionBody(f.node, f.idx);
        }
    }

    // ========================================================================
    // Declarations
    // ========================================================================

    fn createFunction(self: *Lowerer, decl_idx: NodeIdx, name: []const u8) !api.FunctionIdx {
        const f = self.arena.get(decl_idx).fn_decl;
        const ret_ir = self.irTypeFor(self.checker.nodeType(decl_idx));
        const fidx = try self.ctx.addFunction(name, ret_ir, @intCast(f.params.indices.len));
        try self.fn_by_node.put(self.gpa, decl_idx, fidx);
        try self.all_functions.append(self.gpa, .{ .node = decl_idx, .idx = fidx });
        return fidx;
    }

    fn collectMethods(self: *Lowerer, decl_idx: NodeIdx, type_name: []const u8, methods: NodeList) !void {
        const table = try self.methodTableFor(decl_idx);
        for (methods.indices) |method_idx| {
            const method = self.arena.get(method_idx);
            if (method.* != .fn_decl) continue;
            if (method.fn_decl.generic_params.indices.len > 0) continue;
            const method_name = self.nameSlice(method.fn_decl.name);
            const mangled = try std.fmt.allocPrint(self.gpa, "{s}_{s}", .{ type_name, method_name });
            const fidx = try self.createFunction(method_idx, mangled);
            self.gpa.free(mangled);
            const ret_ir = self.irTypeFor(self.checker.nodeType(method_idx));
            try table.by_name.put(self.gpa, method_name, .{ .fidx = fidx, .ret_ir = ret_ir });
            try table.order.append(self.gpa, fidx);
        }
    }

    fn collectImplMethods(self: *Lowerer, decl_idx: NodeIdx, ib: anytype) !void {
        const st = self.arena.get(ib.self_type);
        const type_name_ref: StringRef = switch (st.*) {
            .identifier => |id| id,
            .paren_expr => |p| switch (self.arena.get(p).*) {
                .identifier => |id| id,
                else => return,
            },
            else => return,
        };
        const type_name = self.nameSlice(type_name_ref);
        const sym = self.checker.scopes.scopes.items[0].symbols.get(type_name) orelse {
            self.codegenError(decl_idx, "impl for unknown type '{s}'", .{type_name});
            return;
        };
        const target: NodeIdx = switch (sym.kind) {
            .struct_type, .class_type => sym.decl_node,
            else => return,
        };
        try self.collectMethods(target, type_name, ib.methods);
    }

    fn methodTableFor(self: *Lowerer, decl_idx: NodeIdx) !*MethodTable {
        const gop = try self.methods.getOrPut(self.gpa, decl_idx);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .by_name = .empty, .order = .empty };
        }
        return gop.value_ptr;
    }

    fn lowerFunctionBody(self: *Lowerer, decl_idx: NodeIdx, fidx: api.FunctionIdx) !void {
        self.ctx.setCurrentFunction(fidx);
        self.params.clearRetainingCapacity();
        self.locals.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.pending_defers.clearRetainingCapacity();
        self.block_terminated = false;

        const f = self.arena.get(decl_idx).fn_decl;
        for (f.params.indices, 0..) |param_idx, i| {
            const param = self.arena.get(param_idx);
            try self.params.put(self.gpa, self.nameSlice(param.param.name), .{
                .value = @enumFromInt(i),
                .ty = try self.paramType(param.param.ty),
            });
        }

        const entry = try self.ctx.appendBlock();
        self.setBlock(entry);

        if (f.body != NodeIdx.none) {
            try self.lowerStmt(f.body);
        }

        if (!self.block_terminated) {
            const ret_ty = self.checker.nodeType(decl_idx);
            if (self.type_pool.get(ret_ty) == .void) {
                _ = try self.ctx.buildRetVoid();
            } else {
                _ = try self.ctx.buildRet(try self.ctx.buildIntConst(self.i64_ty, 0));
            }
        }
    }

    // ========================================================================
    // Statements
    // ========================================================================

    fn lowerStmt(self: *Lowerer, node_idx: NodeIdx) anyerror!void {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .block => |b| try self.lowerBlock(b.stmts),
            .let_stmt => try self.lowerLet(node_idx),
            .return_stmt => |r| try self.lowerReturn(r),
            .expr_stmt => |e| _ = try self.lowerExpr(e.expr),
            .defer_stmt => |d| try self.pending_defers.append(self.gpa, d.expr),
            .if_expr => try self.lowerIf(node_idx),
            .while_expr => try self.lowerWhile(node_idx),
            .for_range => try self.lowerForRange(node_idx),
            .for_each => {
                self.codegenError(node_idx, "'for ... in' iteration is not lowered yet", .{});
            },
            .match_expr => try self.lowerMatch(node_idx),
            .fn_decl => {},
            else => _ = try self.lowerExpr(node_idx),
        }
    }

    fn lowerBlock(self: *Lowerer, stmts: NodeList) anyerror!void {
        const defer_marker = self.pending_defers.items.len;
        const local_marker = self.shadows.items.len;

        for (stmts.indices) |stmt_idx| {
            try self.lowerStmt(stmt_idx);
            if (self.block_terminated) break;
        }

        if (!self.block_terminated) {
            try self.flushDefersFrom(defer_marker);
        }
        try self.popLocalScope(local_marker);
    }

    /// Emit pending defers from index `marker` onward, last first.
    fn flushDefersFrom(self: *Lowerer, marker: usize) !void {
        while (self.pending_defers.items.len > marker) {
            const expr = self.pending_defers.items[self.pending_defers.items.len - 1];
            self.pending_defers.items.len -= 1;
            _ = try self.lowerExpr(expr);
        }
    }

    fn popLocalScope(self: *Lowerer, marker: usize) !void {
        while (self.shadows.items.len > marker) {
            const entry = self.shadows.items[self.shadows.items.len - 1];
            self.shadows.items.len -= 1;
            if (entry.prev) |prev| {
                try self.locals.put(self.gpa, entry.name, prev);
            } else {
                _ = self.locals.remove(entry.name);
            }
        }
    }

    fn bindLocal(self: *Lowerer, name: []const u8, slot: api.Value, ty: TypeIdx) !void {
        try self.shadows.append(self.gpa, .{ .name = name, .prev = self.locals.get(name) });
        try self.locals.put(self.gpa, name, .{ .value = slot, .ty = ty });
    }

    fn lowerLet(self: *Lowerer, node_idx: NodeIdx) !void {
        const l = self.arena.get(node_idx).let_stmt;
        const slot = try self.allocVarSlot(self.checker.nodeType(node_idx));
        if (l.init_expr) |init_idx| {
            const val = try self.lowerExpr(init_idx);
            _ = try self.ctx.buildStore(self.i64_ty, slot, val);
        } else {
            _ = try self.ctx.buildStore(self.i64_ty, slot, try self.ctx.buildIntConst(self.i64_ty, 0));
        }
        try self.bindLocal(self.nameSlice(l.name), slot, self.checker.nodeType(node_idx));
    }

    fn allocVarSlot(self: *Lowerer, ty: TypeIdx) !api.Value {
        const size: u32 = switch (self.type_pool.get(ty)) {
            .struct_type => |decl_node| class_mod.structSize(self.arena, decl_node),
            else => 8,
        };
        return self.ctx.buildAllocaBytes(self.ptr_ty, size);
    }

    fn lowerReturn(self: *Lowerer, r: anytype) !void {
        // Deferred expressions run before the function leaves, innermost first.
        try self.flushDefersFrom(0);
        if (r.value) |val_idx| {
            const val = try self.lowerExpr(val_idx);
            _ = try self.ctx.buildRet(val);
        } else {
            _ = try self.ctx.buildRetVoid();
        }
        self.terminated();
    }

    // ========================================================================
    // Control flow
    // ========================================================================

    fn lowerIf(self: *Lowerer, node_idx: NodeIdx) !void {
        const i = self.arena.get(node_idx).if_expr;
        const cond = try self.lowerExpr(i.cond);

        const then_b = try self.ctx.appendBlock();
        const else_b = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(cond, then_b, else_b);

        self.setBlock(then_b);
        try self.lowerStmt(i.then_body);
        if (!self.block_terminated) _ = try self.ctx.buildBr(merge);

        self.setBlock(else_b);
        if (i.else_body) |else_idx| {
            try self.lowerStmt(else_idx);
        }
        if (!self.block_terminated) _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
    }

    fn lowerWhile(self: *Lowerer, node_idx: NodeIdx) !void {
        const w = self.arena.get(node_idx).while_expr;
        const header = try self.ctx.appendBlock();
        const body = try self.ctx.appendBlock();
        const end = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(header);

        self.setBlock(header);
        const cond = try self.lowerExpr(w.cond);
        _ = try self.ctx.buildCondBr(cond, body, end);

        self.setBlock(body);
        try self.lowerStmt(w.body);
        if (!self.block_terminated) _ = try self.ctx.buildBr(header);

        self.setBlock(end);
    }

    fn lowerForRange(self: *Lowerer, node_idx: NodeIdx) !void {
        const fr = self.arena.get(node_idx).for_range;

        // Loop variable lives in a mutable slot; the bound is evaluated once.
        const slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
        _ = try self.ctx.buildStore(self.i64_ty, slot, try self.lowerExpr(fr.start));
        const end = try self.lowerExpr(fr.end);

        const header = try self.ctx.appendBlock();
        const body = try self.ctx.appendBlock();
        const incr = try self.ctx.appendBlock();
        const exit = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(header);

        self.setBlock(header);
        const cur = try self.ctx.buildLoad(self.i64_ty, slot);
        const cond = try self.ctx.buildIcmp(.icmp_slt, self.bool_ty, cur, end);
        _ = try self.ctx.buildCondBr(cond, body, exit);

        self.setBlock(body);
        try self.bindLocal(self.nameSlice(fr.var_name), slot, self.checker.nodeType(fr.start));
        try self.lowerStmt(fr.body);
        if (!self.block_terminated) {
            _ = try self.ctx.buildBr(incr);

            self.setBlock(incr);
            const next = try self.ctx.buildAdd(self.i64_ty, try self.ctx.buildLoad(self.i64_ty, slot), try self.ctx.buildIntConst(self.i64_ty, 1));
            _ = try self.ctx.buildStore(self.i64_ty, slot, next);
            _ = try self.ctx.buildBr(header);
        }
        self.setBlock(exit);
        try self.popLocalScope(self.shadows.items.len - if (self.locals.get(self.nameSlice(fr.var_name)) != null) @as(usize, 1) else 0);
    }

    fn lowerMatch(self: *Lowerer, node_idx: NodeIdx) !void {
        const m = self.arena.get(node_idx).match_expr;
        const scrutinee = try self.lowerExpr(m.scrutinee);

        var arm_consts = std.ArrayList(api.Value).empty;
        defer arm_consts.deinit(self.gpa);
        for (m.arms.indices) |arm_idx| {
            const arm = self.arena.get(arm_idx);
            const pattern = self.arena.get(arm.match_arm.pattern);
            const value = switch (pattern.*) {
                .int_literal => |v| try self.ctx.buildIntConst(self.i64_ty, v),
                else => blk: {
                    self.codegenError(arm_idx, "only integer match patterns are lowered", .{});
                    break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
                },
            };
            try arm_consts.append(self.gpa, value);
        }

        var checks = std.ArrayList(api.BasicBlockIdx).empty;
        defer checks.deinit(self.gpa);
        var bodies = std.ArrayList(api.BasicBlockIdx).empty;
        defer bodies.deinit(self.gpa);
        for (m.arms.indices) |_| {
            try checks.append(self.gpa, try self.ctx.appendBlock());
            try bodies.append(self.gpa, try self.ctx.appendBlock());
        }
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(checks.items[0]);

        for (m.arms.indices, 0..) |arm_idx, i| {
            self.setBlock(checks.items[i]);
            const match_cond = try self.ctx.buildIcmp(.icmp_eq, self.bool_ty, scrutinee, arm_consts.items[i]);
            const next_check = if (i + 1 < checks.items.len) checks.items[i + 1] else merge;
            _ = try self.ctx.buildCondBr(match_cond, bodies.items[i], next_check);

            self.setBlock(bodies.items[i]);
            const arm = self.arena.get(arm_idx);
            try self.lowerStmt(arm.match_arm.body);
            if (!self.block_terminated) _ = try self.ctx.buildBr(merge);
        }

        self.setBlock(merge);
    }

    // ========================================================================
    // Expressions
    // ========================================================================

    fn lowerExpr(self: *Lowerer, node_idx: NodeIdx) !api.Value {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .int_literal => |v| return self.ctx.buildIntConst(self.irTypeFor(self.checker.nodeType(node_idx)), v),
            .float_literal => |v| return self.ctx.buildFloatConst(self.irTypeFor(self.checker.nodeType(node_idx)), v),
            .bool_literal => |v| return self.ctx.buildIntConst(self.bool_ty, if (v) 1 else 0),
            .null_literal => return self.ctx.buildIntConst(self.i64_ty, 0),
            .char_literal => |ref| return self.lowerChar(ref),
            .string_literal => |ref| return self.lowerString(ref),
            .identifier => |id| return self.lowerIdentifier(node_idx, id),
            .binary_op => |b| return self.lowerBinary(node_idx, b),
            .unary_op => |u| return self.lowerUnary(node_idx, u),
            .call => |c| return self.lowerCall(node_idx, c),
            .field_access => |fa| {
                if (try self.lowerFieldAddr(node_idx, fa)) |addr| {
                    return self.ctx.buildLoad(self.i64_ty, addr);
                }
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .index_access => {
                self.codegenError(node_idx, "index access is not lowered yet", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .paren_expr => |p| return self.lowerExpr(p),
            .struct_init => |si| return self.lowerStructInit(node_idx, si),
            .range_expr => {
                self.codegenError(node_idx, "range expression outside of a for loop", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .if_expr, .match_expr, .while_expr, .for_range, .for_each => {
                self.codegenError(node_idx, "control flow in expression position is not supported yet", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .block => |b| return self.lowerBlockValue(b),
            else => {
                self.codegenError(node_idx, "expression not lowered", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        }
    }

    fn lowerBlockValue(self: *Lowerer, b: anytype) !api.Value {
        const defer_marker = self.pending_defers.items.len;
        const local_marker = self.shadows.items.len;
        var last_val: api.Value = undefined;
        var has_value = false;

        for (b.stmts.indices, 0..) |stmt_idx, i| {
            if (self.block_terminated) break;
            const node = self.arena.get(stmt_idx);
            if (i + 1 == b.stmts.indices.len and node.* == .expr_stmt) {
                last_val = try self.lowerExpr(node.expr_stmt.expr);
                has_value = true;
            } else {
                try self.lowerStmt(stmt_idx);
            }
        }

        if (!self.block_terminated) {
            try self.flushDefersFrom(defer_marker);
        }
        try self.popLocalScope(local_marker);

        if (has_value) return last_val;
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    fn lowerChar(self: *Lowerer, ref: StringRef) !api.Value {
        const raw = ref.slice(self.source);
        const body = raw[1 .. raw.len - 1];
        const bytes = try string_mod.unescape(self.gpa, body);
        defer self.gpa.free(bytes);
        const value: i64 = if (bytes.len > 0) bytes[0] else 0;
        return self.ctx.buildIntConst(self.i32_ty, value);
    }

    fn lowerString(self: *Lowerer, ref: StringRef) !api.Value {
        const raw = ref.slice(self.source);
        const bytes = try string_mod.unescape(self.gpa, raw[1 .. raw.len - 1]);
        defer self.gpa.free(bytes);
        const global = try self.strings.globalFor(bytes);

        const repr = try self.ctx.buildAllocaBytes(self.ptr_ty, string_mod.total_size);
        _ = try self.ctx.buildStore(self.i64_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(bytes.len)));
        const data = try self.ctx.buildGlobalAddr(self.ptr_ty, global);
        const data_addr = try self.ctx.buildPtrAdd(self.ptr_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.data_offset)));
        _ = try self.ctx.buildStore(self.i64_ty, data_addr, data);
        return repr;
    }

    fn lowerIdentifier(self: *Lowerer, node_idx: NodeIdx, id: StringRef) !api.Value {
        const name = self.nameSlice(id);
        if (self.params.get(name)) |param| return param.value;
        if (self.locals.get(name)) |binding| {
            return self.ctx.buildLoad(self.i64_ty, binding.value);
        }
        self.codegenError(node_idx, "unknown identifier '{s}'", .{name});
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    fn lowerBinary(self: *Lowerer, node_idx: NodeIdx, b: anytype) !api.Value {
        if (b.op == .assign or b.op == .add_assign or b.op == .sub_assign or
            b.op == .mul_assign or b.op == .div_assign)
        {
            return self.lowerAssign(node_idx, b);
        }

        const lhs = try self.lowerExpr(b.left);
        const rhs = try self.lowerExpr(b.right);
        const left_ty = self.exprType(b.left);
        const sem = self.type_pool.get(left_ty);
        const is_float = sem == .float;
        const ir_ty = self.irTypeFor(left_ty);

        return switch (b.op) {
            .add => if (is_float) self.ctx.buildFAdd(ir_ty, lhs, rhs) else self.ctx.buildAdd(ir_ty, lhs, rhs),
            .sub => if (is_float) self.ctx.buildFSub(ir_ty, lhs, rhs) else self.ctx.buildSub(ir_ty, lhs, rhs),
            .mul => if (is_float) self.ctx.buildFMul(ir_ty, lhs, rhs) else self.ctx.buildMul(ir_ty, lhs, rhs),
            .div => if (is_float) self.ctx.buildFDiv(ir_ty, lhs, rhs) else if (sem.int.signed) self.ctx.buildSDiv(ir_ty, lhs, rhs) else self.ctx.buildUDiv(ir_ty, lhs, rhs),
            .mod => if (is_float) blk: {
                self.codegenError(node_idx, "modulo on float operands", .{});
                break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
            } else if (sem.int.signed) self.ctx.buildSRem(ir_ty, lhs, rhs) else self.ctx.buildURem(ir_ty, lhs, rhs),
            .bit_and => self.ctx.buildAnd(ir_ty, lhs, rhs),
            .bit_or => self.ctx.buildOr(ir_ty, lhs, rhs),
            .bit_xor => self.ctx.buildXor(ir_ty, lhs, rhs),
            .shift_left => self.ctx.buildShl(ir_ty, lhs, rhs),
            .shift_right => self.ctx.buildShr(ir_ty, lhs, rhs),
            .eq, .ne, .lt, .gt, .le, .ge => self.lowerCompare(sem, ir_ty, b.op, lhs, rhs),
            .and_op => self.lowerLogicalAnd(b),
            .or_op => self.lowerLogicalOr(b),
            .range => blk: {
                self.codegenError(node_idx, "range expression outside of a for loop", .{});
                break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => unreachable,
        };
    }

    fn lowerCompare(self: *Lowerer, sem: SemType, ir_ty: api.TypeIdx, op: BinaryOp, lhs: api.Value, rhs: api.Value) !api.Value {
        if (sem == .float) {
            const cond: api.Opcode = switch (op) {
                .eq => .fcmp_oeq,
                .ne => .fcmp_one,
                .lt => .fcmp_olt,
                .le => .fcmp_ole,
                .gt => .fcmp_ogt,
                .ge => .fcmp_oge,
                else => unreachable,
            };
            return self.ctx.buildFCmp(cond, ir_ty, lhs, rhs);
        }
        const signed = sem == .int and sem.int.signed;
        const cond: api.Opcode = switch (op) {
            .eq => .icmp_eq,
            .ne => .icmp_ne,
            .lt => if (signed) .icmp_slt else .icmp_ult,
            .le => if (signed) .icmp_sle else .icmp_ule,
            .gt => if (signed) .icmp_sgt else .icmp_ugt,
            .ge => if (signed) .icmp_sge else .icmp_uge,
            else => unreachable,
        };
        return self.ctx.buildIcmp(cond, self.bool_ty, lhs, rhs);
    }

    fn lowerLogicalAnd(self: *Lowerer, b: anytype) !api.Value {
        const lhs = try self.lowerExpr(b.left);
        const rhs_block = try self.ctx.appendBlock();
        const false_block = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(lhs, rhs_block, false_block);

        self.setBlock(rhs_block);
        const rhs = try self.lowerExpr(b.right);
        const has_rhs = !self.block_terminated;
        if (has_rhs) _ = try self.ctx.buildBr(merge);

        self.setBlock(false_block);
        const zero = try self.ctx.buildIntConst(self.bool_ty, 0);
        _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        if (has_rhs) try incoming.append(self.gpa, .{ .value = rhs, .block = rhs_block });
        try incoming.append(self.gpa, .{ .value = zero, .block = false_block });
        return self.ctx.buildPhi(self.bool_ty, incoming.items);
    }

    fn lowerLogicalOr(self: *Lowerer, b: anytype) !api.Value {
        const lhs = try self.lowerExpr(b.left);
        const true_block = try self.ctx.appendBlock();
        const rhs_block = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(lhs, true_block, rhs_block);

        self.setBlock(true_block);
        const one = try self.ctx.buildIntConst(self.bool_ty, 1);
        _ = try self.ctx.buildBr(merge);

        self.setBlock(rhs_block);
        const rhs = try self.lowerExpr(b.right);
        const has_rhs = !self.block_terminated;
        if (has_rhs) _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        try incoming.append(self.gpa, .{ .value = one, .block = true_block });
        if (has_rhs) try incoming.append(self.gpa, .{ .value = rhs, .block = rhs_block });
        return self.ctx.buildPhi(self.bool_ty, incoming.items);
    }

    fn lowerAssign(self: *Lowerer, node_idx: NodeIdx, b: anytype) !api.Value {
        const addr = try self.lowerLvalue(b.left) orelse {
            self.codegenError(node_idx, "invalid assignment target", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        const rhs = try self.lowerExpr(b.right);

        if (b.op == .assign) {
            _ = try self.ctx.buildStore(self.i64_ty, addr, rhs);
            return rhs;
        }

        const cur = try self.ctx.buildLoad(self.i64_ty, addr);
        const sem = self.type_pool.get(self.checker.nodeType(b.left));
        const ir_ty = self.irTypeForSem(sem);
        const is_float = sem == .float;
        const result = switch (b.op) {
            .add_assign => if (is_float) try self.ctx.buildFAdd(ir_ty, cur, rhs) else try self.ctx.buildAdd(ir_ty, cur, rhs),
            .sub_assign => if (is_float) try self.ctx.buildFSub(ir_ty, cur, rhs) else try self.ctx.buildSub(ir_ty, cur, rhs),
            .mul_assign => if (is_float) try self.ctx.buildFMul(ir_ty, cur, rhs) else try self.ctx.buildMul(ir_ty, cur, rhs),
            .div_assign => if (is_float) try self.ctx.buildFDiv(ir_ty, cur, rhs) else if (sem.int.signed) try self.ctx.buildSDiv(ir_ty, cur, rhs) else try self.ctx.buildUDiv(ir_ty, cur, rhs),
            else => unreachable,
        };
        _ = try self.ctx.buildStore(self.i64_ty, addr, result);
        return result;
    }

    fn lowerUnary(self: *Lowerer, node_idx: NodeIdx, u: anytype) !api.Value {
        const operand = try self.lowerExpr(u.operand);
        const sem = self.type_pool.get(self.checker.nodeType(u.operand));
        const is_float = sem == .float;
        const ir_ty = self.irTypeFor(self.checker.nodeType(u.operand));

        return switch (u.op) {
            .neg => if (is_float)
                self.ctx.buildFSub(ir_ty, try self.ctx.buildFloatConst(ir_ty, 0.0), operand)
            else
                self.ctx.buildSub(ir_ty, try self.ctx.buildIntConst(ir_ty, 0), operand),
            .not => self.ctx.buildXor(self.bool_ty, operand, try self.ctx.buildIntConst(self.bool_ty, 1)),
            .bit_not => self.ctx.buildXor(ir_ty, operand, try self.ctx.buildIntConst(ir_ty, -1)),
            .deref, .ref => blk: {
                self.codegenError(node_idx, "explicit dereference/reference is not lowered yet", .{});
                break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
            },
        };
    }

    fn lowerCall(self: *Lowerer, node_idx: NodeIdx, c: anytype) !api.Value {
        const callee = self.arena.get(c.func);
        switch (callee.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                const sym = self.checker.scopes.scopes.items[0].symbols.get(name) orelse {
                    self.codegenError(node_idx, "unknown function '{s}'", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                if (sym.kind != .function) {
                    self.codegenError(node_idx, "'{s}' is not a function", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                }
                const fidx = self.fn_by_node.get(sym.decl_node) orelse {
                    self.codegenError(node_idx, "function '{s}' has no lowering", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                const ret_ir = self.irTypeFor(self.checker.nodeType(sym.decl_node));
                var args = try self.lowerArgs(c.args);
                defer args.deinit(self.gpa);
                return self.ctx.buildCall(fidx, ret_ir, args.items);
            },
            .field_access => |fa| {
                const obj = try self.lowerExpr(fa.object);
                const decl_node = self.declNodeOfType(self.exprType(fa.object)) orelse {
                    self.codegenError(node_idx, "method call on non-struct/class value", .{});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                const table = self.methods.get(decl_node) orelse {
                    self.codegenError(node_idx, "type has no methods", .{});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                const entry = table.by_name.get(self.nameSlice(fa.field)) orelse {
                    self.codegenError(node_idx, "no method '{s}'", .{self.nameSlice(fa.field)});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                var args = try self.lowerArgs(c.args);
                defer args.deinit(self.gpa);
                var all_args = std.ArrayList(api.Value).empty;
                defer all_args.deinit(self.gpa);
                try all_args.append(self.gpa, obj);
                try all_args.appendSlice(self.gpa, args.items);
                return self.ctx.buildCall(entry.fidx, entry.ret_ir, all_args.items);
            },
            else => {
                self.codegenError(node_idx, "unsupported callee", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        }
    }

    fn lowerArgs(self: *Lowerer, list: NodeList) !std.ArrayList(api.Value) {
        var args = std.ArrayList(api.Value).empty;
        errdefer args.deinit(self.gpa);
        for (list.indices) |arg_idx| {
            try args.append(self.gpa, try self.lowerExpr(arg_idx));
        }
        return args;
    }

    fn lowerStructInit(self: *Lowerer, node_idx: NodeIdx, si: anytype) !api.Value {
        const ty = self.checker.nodeType(si.ty);
        const sem = self.type_pool.get(ty);
        const decl_node = switch (sem) {
            .struct_type => |n| n,
            .class_type => |n| n,
            else => {
                self.codegenError(node_idx, "struct init on a non-struct/class type", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        };
        const is_class = sem == .class_type;

        var base: api.Value = undefined;
        if (is_class) {
            const vtable_g = self.vtable_by_class.get(decl_node) orelse {
                self.codegenError(node_idx, "class has no vtable", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            };
            const size_val = try self.ctx.buildIntConst(self.i64_ty, class_mod.classSize(self.arena, decl_node));
            base = try self.ctx.buildMalloc(self.ptr_ty, size_val);
            _ = try self.ctx.buildStore(self.i64_ty, base, try self.ctx.buildGlobalAddr(self.ptr_ty, vtable_g));
            const rc_addr = try self.ctx.buildPtrAdd(self.ptr_ty, base, try self.ctx.buildIntConst(self.i64_ty, @intCast(class_mod.ref_count_offset)));
            _ = try self.ctx.buildStore(self.i64_ty, rc_addr, try self.ctx.buildIntConst(self.i64_ty, 0));
        } else {
            base = try self.ctx.buildAllocaBytes(self.ptr_ty, class_mod.structSize(self.arena, decl_node));
        }

        const decl = self.arena.get(decl_node);
        const fields: []const NodeIdx = switch (decl.*) {
            .struct_decl => |s| s.fields.indices,
            .class_decl => |c| c.fields.indices,
            else => &.{},
        };

        // Each field slot gets its initializer, or zero if omitted.
        const field_base: u64 = if (is_class) class_mod.class_header_size else 0;
        for (fields, 0..) |field_idx, i| {
            const field_name = self.nameSlice(self.arena.get(field_idx).field.name);
            const offset: u64 = field_base + 8 * @as(u64, @intCast(i));
            var init_val: ?api.Value = null;
            for (si.fields.indices) |init_idx| {
                const init_field = self.arena.get(init_idx).struct_init_field;
                if (std.mem.eql(u8, self.nameSlice(init_field.name), field_name)) {
                    init_val = try self.lowerExpr(init_field.value);
                    break;
                }
            }
            const addr = try self.ctx.buildPtrAdd(self.ptr_ty, base, try self.ctx.buildIntConst(self.i64_ty, @intCast(offset)));
            if (init_val) |v| {
                _ = try self.ctx.buildStore(self.i64_ty, addr, v);
            } else {
                _ = try self.ctx.buildStore(self.i64_ty, addr, try self.ctx.buildIntConst(self.i64_ty, 0));
            }
        }
        return base;
    }

    fn lowerFieldAddr(self: *Lowerer, node_idx: NodeIdx, fa: anytype) anyerror!?api.Value {
        const obj = try self.lowerExpr(fa.object);
        const obj_ty = self.exprType(fa.object);
        const sem = self.type_pool.get(obj_ty);
        const field_name = self.nameSlice(fa.field);

        var decl_node: ?NodeIdx = null;
        var is_class = false;
        switch (sem) {
            .struct_type => |n| decl_node = n,
            .class_type => |n| {
                decl_node = n;
                is_class = true;
            },
            .pointer => |elem| switch (self.type_pool.get(elem)) {
                .struct_type => |n| decl_node = n,
                .class_type => |n| {
                    decl_node = n;
                    is_class = true;
                },
                else => {},
            },
            else => {},
        }
        const target = decl_node orelse {
            self.codegenError(node_idx, "field access on a non-struct/class type", .{});
            return null;
        };

        const offset = if (is_class)
            class_mod.classFieldOffset(self.arena, self.source, target, field_name)
        else
            class_mod.structFieldOffset(self.arena, self.source, target, field_name);
        const off = offset orelse {
            self.codegenError(node_idx, "no such field '{s}'", .{field_name});
            return null;
        };

        const off_val = try self.ctx.buildIntConst(self.i64_ty, @intCast(off));
        return try self.ctx.buildPtrAdd(self.ptr_ty, obj, off_val);
    }

    fn lowerLvalue(self: *Lowerer, node_idx: NodeIdx) !?api.Value {
        const node = self.arena.get(node_idx);
        return switch (node.*) {
            .identifier => |id| blk: {
                const name = self.nameSlice(id);
                if (self.locals.get(name)) |binding| break :blk binding.value;
                if (self.params.get(name) != null) {
                    self.codegenError(node_idx, "cannot assign to parameter '{s}'", .{name});
                } else {
                    self.codegenError(node_idx, "unknown identifier '{s}'", .{name});
                }
                break :blk null;
            },
            .field_access => |fa| try self.lowerFieldAddr(node_idx, fa),
            else => null,
        };
    }

    // ========================================================================
    // Types
    // ========================================================================

    fn irTypeFor(self: *Lowerer, ty: TypeIdx) api.TypeIdx {
        return self.irTypeForSem(self.type_pool.get(ty));
    }

    fn irTypeForSem(self: *Lowerer, sem: SemType) api.TypeIdx {
        return switch (sem) {
            .void => self.void_ty,
            .bool_type => self.bool_ty,
            .int => |i| if (i.signed)
                switch (i.bits) {
                    8 => self.i8_ty,
                    16 => self.i16_ty,
                    32 => self.i32_ty,
                    else => self.i64_ty,
                }
            else
                switch (i.bits) {
                    8 => self.u8_ty,
                    16 => self.u16_ty,
                    32 => self.u32_ty,
                    else => self.u64_ty,
                },
            .float => |f| switch (f) {
                .f32 => self.f32_ty,
                .f64 => self.f64_ty,
                .f16 => self.f64_ty,
            },
            // Pointers, strings, structs and classes all live in one slot.
            else => self.ptr_ty,
        };
    }

    fn declNodeOfType(self: *Lowerer, ty: TypeIdx) ?NodeIdx {
        const sem = self.type_pool.get(ty);
        return switch (sem) {
            .struct_type => |n| n,
            .class_type => |n| n,
            .pointer => |elem| self.declNodeOfType(elem),
            else => null,
        };
    }

    /// Semantic type of a function parameter's type node. The checker caches
    /// the pointee's type on `*T` unary nodes but not the pointer itself, so
    /// pointer types are rebuilt here.
    fn paramType(self: *Lowerer, ty_node: NodeIdx) !TypeIdx {
        const node = self.arena.get(ty_node);
        if (node.* == .unary_op and node.unary_op.op == .deref) {
            const pointee = self.checker.nodeType(node.unary_op.operand);
            return try self.type_pool.add(.{ .pointer = pointee });
        }
        return self.checker.nodeType(ty_node);
    }

    /// Semantic type of a local/param binding by name, if any.
    fn bindingType(self: *Lowerer, name: []const u8) ?TypeIdx {
        if (self.params.get(name)) |p| return p.ty;
        if (self.locals.get(name)) |l| return l.ty;
        return null;
    }

    /// Type of an expression node, falling back to the binding map for
    /// identifiers that the type checker never visited (e.g. method-call
    /// receivers, which its `.call` rule does not traverse).
    fn exprType(self: *Lowerer, node_idx: NodeIdx) TypeIdx {
        const node = self.arena.get(node_idx);
        if (node.* == .identifier) {
            if (self.bindingType(self.nameSlice(node.identifier))) |ty| return ty;
        }
        return self.checker.nodeType(node_idx);
    }

    // ========================================================================
    // Misc
    // ========================================================================

    fn setBlock(self: *Lowerer, block: api.BasicBlockIdx) void {
        self.ctx.setCurrentBlock(block);
        self.block_terminated = false;
    }

    fn terminated(self: *Lowerer) void {
        self.block_terminated = true;
    }

    fn nameSlice(self: *Lowerer, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn codegenError(self: *Lowerer, _: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch |err| {
            std.debug.panic("OOM in codegen: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .codegen, msg, null) catch {};
    }
};

/// Lower a fully checked module into `ctx`.
pub fn lowerAll(
    gpa: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    checker: *typecheck_mod.TypeChecker,
    ctx: *api.Context,
) !void {
    var lowerer = try Lowerer.init(gpa, arena, source, type_pool, diagnostics, checker, ctx);
    defer lowerer.deinit();
    try lowerer.run();
}

// ============================================================================
// Tests
// ============================================================================

const TestResult = struct {
    arena: AstArena,
    type_pool: TypePool,
    diagnostics: diag.Diagnostics,
    ctx: *api.Context,

    fn deinit(self: *TestResult) void {
        self.ctx.deinit();
        self.arena.deinit();
        self.type_pool.deinit();
        self.diagnostics.deinit();
    }

    fn text(self: *TestResult, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        self.ctx.print(&w) catch unreachable;
        return buf[0..w.end];
    }
};

fn runLower(allocator: Allocator, source: []const u8) !TestResult {
    var arena = AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = TypePool.init(allocator);
    var checker: typecheck_mod.TypeChecker = undefined;
    {
        var resolver = @import("../semantic/resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
        defer resolver.deinit();
        try resolver.resolve();
        checker = typecheck_mod.TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
        try checker.check();
    }
    const ctx = try api.Context.init(allocator);
    errdefer ctx.deinit();
    try lowerAll(allocator, &arena, source, &type_pool, &diags, &checker, ctx);
    checker.deinit();
    return .{ .arena = arena, .type_pool = type_pool, .diagnostics = diags, .ctx = ctx };
}

fn checkLower(allocator: Allocator, source: []const u8) !TestResult {
    var res = try runLower(allocator, source);
    errdefer {
        res.ctx.deinit();
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    return res;
}

test "lower: int return" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @main() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %0") != null);
}

test "lower: arithmetic and calls" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(3, 4)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "add %0, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn0(%") != null);
}

test "lower: if statement with else and assignment" {
    var res = try checkLower(std.testing.allocator,
        \\fn sign(x: i32) -> i32 {
        \\    mut r: i32 = 0
        \\    if x > 0 {
        \\        r = 1
        \\    } else {
        \\        r = -1
        \\    }
        \\    return r
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store") != null);
}

test "lower: while loop" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    mut i: i32 = 0
        \\    while i < 10 {
        \\        s = s + i
        \\        i = i + 1
        \\    }
        \\    return s
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp slt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb1:") != null);
}

test "lower: for range loop" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    for i in 0..10 {
        \\        s = s + i
        \\    }
        \\    return s
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp slt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load") != null);
}

test "lower: short-circuit and with phi" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> bool {
        \\    let b := 1 < 2 && 3 < 4
        \\    return b
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
}

test "lower: struct init and field access" {
    var res = try checkLower(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn main() -> f64 {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    return v.x
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fconst 1") != null);
}

test "lower: class new with vtable and malloc" {
    var res = try checkLower(std.testing.allocator,
        \\class Animal {
        \\    name: i32
        \\}
        \\fn main() -> i32 {
        \\    let a: Animal = Animal{ .name = 7 }
        \\    return a.name
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "global @vtable_Animal = fn_array [") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "malloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr @vtable_Animal") != null);
}

test "lower: string literal pool" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let s: String = "hi"
        \\    return 0
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "global @str_0 = string \"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
}

test "lower: method call passes receiver first" {
    var res = try checkLower(std.testing.allocator,
        \\class Dog {
        \\    name: i32
        \\    fn speak(self: *Dog) -> i32 {
        \\        return self.name
        \\    }
        \\}
        \\fn main() -> i32 {
        \\    let d: Dog = Dog{ .name = 3 }
        \\    return d.speak()
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "global @vtable_Dog = fn_array [@fn0]") != null);

    const asm_text = try res.ctx.emitAssembly();
    defer res.ctx.gpa.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "_Dog_speak") != null);
}

test "lower: defers run before return" {
    var res = try checkLower(std.testing.allocator,
        \\fn g() {
        \\}
        \\fn f() -> i32 {
        \\    defer g()
        \\    return 1
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    const call_pos = std.mem.indexOf(u8, text, "call @fn0(").?;
    const ret_pos = std.mem.indexOf(u8, text, "ret %").?;
    try std.testing.expect(call_pos < ret_pos);
}

test "lower: float arithmetic and compare" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> bool {
        \\    return 1.5 + 2.5 >= 3.0
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp oge") != null);
}

test "lower: emit assembly for a module" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer res.deinit();

    const asm_text = try res.ctx.emitAssembly();
    defer res.ctx.gpa.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "section .text") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "_main:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rax, 42") != null);
}
