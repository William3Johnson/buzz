const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const _obj = @import("./obj.zig");
const _token = @import("./token.zig");
const _value = @import("./value.zig");
const _codegen = @import("./codegen.zig");
const _parser = @import("./parser.zig");
const _chunk = @import("./chunk.zig");
const disassembler = @import("./disassembler.zig");
const Config = @import("./config.zig").Config;
const VM = @import("./vm.zig").VM;
const GarbageCollector = @import("./memory.zig").GarbageCollector;

const disassembleChunk = disassembler.disassembleChunk;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjString = _obj.ObjString;
const ObjNative = _obj.ObjNative;
const ObjFunction = _obj.ObjFunction;
const ObjObject = _obj.ObjObject;
const ObjList = _obj.ObjList;
const ObjEnum = _obj.ObjEnum;
const ObjPattern = _obj.ObjPattern;
const ObjMap = _obj.ObjMap;
const ObjBoundMethod = _obj.ObjBoundMethod;
const FunctionType = ObjFunction.FunctionType;
const copyObj = _obj.copyObj;
const Value = _value.Value;
const valueToString = _value.valueToString;
const floatToInteger = _value.floatToInteger;
const Token = _token.Token;
const TokenType = _token.TokenType;
const CodeGen = _codegen.CodeGen;
const Parser = _parser.Parser;
const Frame = _codegen.Frame;
const Local = _parser.Local;
const Global = _parser.Global;
const UpValue = _parser.UpValue;
const OpCode = _chunk.OpCode;

pub const GenError = error{NotConstant};

pub const ParsedArg = struct {
    name: ?Token,
    arg: *ParseNode,
};

pub const ParseNodeType = enum(u8) {
    Function,
    Enum,
    VarDeclaration,
    FunDeclaration,
    ObjectDeclaration,
    Binary,
    Unary,
    Subscript,
    Unwrap,
    ForceUnwrap,
    Is,
    Expression,
    NamedVariable,
    Number,
    String,
    StringLiteral,
    Pattern,
    Boolean,
    Null,
    List,
    Map,
    Super,
    Dot,
    ObjectInit,
    Throw,
    Break,
    Continue,
    Call,
    AsyncCall,
    Resume,
    Resolve,
    Yield,
    If,
    Block,
    Return,
    For,
    ForEach,
    DoUntil,
    While,
    Export,
    Import,
    Try,
};

pub const ToJsonError = Allocator.Error || std.fmt.BufPrintError;

pub const ParseNode = struct {
    const Self = @This();

    node_type: ParseNodeType,
    // If null, either its a statement or its a reference to something unkown that should ultimately raise a compile error
    type_def: ?*ObjTypeDef = null,
    location: Token = undefined,
    end_location: Token = undefined,
    // Wether optional jumps must be patch before generate this node bytecode
    patch_opt_jumps: bool = false,
    docblock: ?Token = null,

    // Does this node closes a scope
    ends_scope: ?std.ArrayList(OpCode) = null,

    toJson: fn (*Self, std.ArrayList(u8).Writer) ToJsonError!void = stringify,
    toByteCode: fn (*Self, *CodeGen, ?*std.ArrayList(usize)) anyerror!?*ObjFunction = generate,
    toValue: fn (*Self, *GarbageCollector) anyerror!Value = val,
    isConstant: fn (*Self) bool,

    pub fn constant(_: *Self) bool {
        return false;
    }

    fn val(_: *Self, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(_: *Self, _: *CodeGen, _: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        return null;
    }

    // If returns true, node must be skipped
    pub fn synchronize(self: *Self, codegen: *CodeGen) bool {
        if (codegen.panic_mode) {
            switch (self.node_type) {
                .ObjectDeclaration,
                .Enum,
                .FunDeclaration,
                .If,
                .While,
                .DoUntil,
                .For,
                .ForEach,
                .Return,
                .VarDeclaration,
                .Throw,
                .Break,
                .Continue,
                .Export,
                .Import,
                => {
                    codegen.panic_mode = false;
                    return false;
                },
                else => {},
            }

            return true;
        }

        return false;
    }

    fn patchOptJumps(self: *Self, codegen: *CodeGen) !void {
        if (self.patch_opt_jumps) {
            assert(codegen.opt_jumps != null);

            // Hope over OP_POP if actual value
            const njump: usize = try codegen.emitJump(self.location, .OP_JUMP);

            for (codegen.opt_jumps.?.items) |jump| {
                try codegen.patchJump(jump);
            }
            // If aborted by a null optional, will result in null on the stack
            try codegen.emitOpCode(self.location, .OP_POP);

            try codegen.patchJump(njump);

            codegen.opt_jumps.?.deinit();
            codegen.opt_jumps = null;
        }
    }

    fn stringify(self: *Self, out: std.ArrayList(u8).Writer) ToJsonError!void {
        try out.writeAll("\"type_def\": \"");
        if (self.type_def) |type_def| {
            try type_def.toString(out);
        } else {
            try out.writeAll("N/A");
        }

        // TODO: assumes a token is on one line, right now it's completely true except for a .Docblock token
        const end_col: usize = if (self.location.eql(self.end_location)) self.location.column + self.location.lexeme.len else self.end_location.column;

        try out.print(
            "\", \"location\": {{ \"start_line\": {}, \"start_column\": {}, \"end_line\": {}, \"end_column\": {}, \"script\": \"{s}\"}}",
            .{
                self.location.line,
                self.location.column,
                self.end_location.line,
                end_col,
                self.location.script_name,
            },
        );

        if (self.docblock != null) {
            try out.print(", \"docblock\": \"{s}\"", .{self.docblock.?.literal_string.?});
        }
    }

    fn endScope(self: *Self, codegen: *CodeGen) anyerror!void {
        if (self.ends_scope) |closing| {
            for (closing.items) |op| {
                try codegen.emitOpCode(self.location, op);
            }
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.ends_scope) {
            self.ends_scope.?.deinit();
        }
    }
};

pub const ExpressionNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Expression,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    expression: *ParseNode,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.expression.isConstant(self.expression);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            return self.expression.toValue(self.expression, gc);
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.expression.toByteCode(self.expression, codegen, breaks);

        try codegen.emitOpCode(node.location, .OP_POP);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Expression\", ", .{});

        try ParseNode.stringify(node, out);

        try out.writeAll(",\"expression\": ");

        try self.expression.toJson(self.expression, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Expression) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const SlotType = enum(u8) {
    Local,
    UpValue,
    Global,
};

pub const NamedVariableNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .NamedVariable,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    identifier: Token,
    value: ?*ParseNode = null,
    slot: usize,
    slot_type: SlotType,
    slot_constant: bool,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        var get_op: OpCode = undefined;
        var set_op: OpCode = undefined;

        switch (self.slot_type) {
            .Local => {
                get_op = .OP_GET_LOCAL;
                set_op = .OP_SET_LOCAL;
            },
            .Global => {
                get_op = .OP_GET_GLOBAL;
                set_op = .OP_SET_GLOBAL;
            },
            .UpValue => {
                get_op = .OP_GET_UPVALUE;
                set_op = .OP_SET_UPVALUE;
            },
        }

        if (self.value) |value| {
            // Type checking
            if (node.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(node.type_def.?.resolved_type.?.Placeholder);
            }

            if (!node.type_def.?.eql(value.type_def.?)) {
                try codegen.reportTypeCheckAt(node.type_def.?, value.type_def.?, "Bad value type", value.location);
            }

            _ = try value.toByteCode(value, codegen, breaks);

            try codegen.emitCodeArg(self.node.location, set_op, @intCast(u24, self.slot));
        } else {
            try codegen.emitCodeArg(self.node.location, get_op, @intCast(u24, self.slot));
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print(
            "{{\"node\": \"NamedVariable\", \"identifier\": \"{s}\", \"slot\": \"{}\", \"slot_type\": \"{}\",",
            .{
                if (self.identifier.literal_string) |literal| literal else "unknown",
                self.slot,
                self.slot_type,
            },
        );

        try ParseNode.stringify(node, out);

        try out.writeAll(",\"value\": ");

        if (self.value) |value| {
            try value.toJson(value, out);
        } else {
            try out.writeAll("null");
        }

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .NamedVariable) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const NumberNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Number,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = cnst,
    },

    float_constant: ?f64,
    integer_constant: ?i64,

    fn cnst(_: *ParseNode) bool {
        return true;
    }

    fn val(node: *ParseNode, _: *GarbageCollector) anyerror!Value {
        const self = Self.cast(node).?;

        if (self.float_constant) |constant| {
            return Value{ .Float = constant };
        } else {
            assert(self.integer_constant != null);

            return Value{ .Integer = self.integer_constant.? };
        }
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.float_constant) |constant| {
            try codegen.emitConstant(self.node.location, Value{ .Float = constant });
        } else {
            assert(self.integer_constant != null);

            try codegen.emitConstant(self.node.location, Value{ .Integer = self.integer_constant.? });
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Number\", \"constant\": ", .{});

        if (self.float_constant) |constant| {
            try out.print("{d}, ", .{constant});
        } else {
            assert(self.integer_constant != null);

            try out.print("{d}, ", .{self.integer_constant.?});
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Number) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BooleanNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Boolean,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = cnts,
    },

    constant: bool,

    fn cnts(_: *ParseNode) bool {
        return true;
    }

    fn val(node: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return Value{ .Boolean = Self.cast(node).?.constant };
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitOpCode(self.node.location, if (self.constant) .OP_TRUE else .OP_FALSE);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Boolean\", \"constant\": \"{}\", ", .{self.constant});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Boolean) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const StringLiteralNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .StringLiteral,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = cnst,
    },

    constant: *ObjString,

    fn cnst(_: *ParseNode) bool {
        return true;
    }

    fn val(node: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return Self.cast(node).?.constant.toValue();
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitConstant(self.node.location, self.constant.toValue());

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        // var self = Self.cast(node).?;

        try out.print("{{\"node\": \"StringLiteral\", \"constant\": \"__TODO_ESCAPE_QUOTES__\", ", .{}); //.{self.constant.string});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .StringLiteral) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const PatternNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Pattern,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = cnst,
    },

    constant: *ObjPattern,

    fn cnst(_: *ParseNode) bool {
        return true;
    }

    fn val(node: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return Self.cast(node).?.constant.toValue();
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitConstant(self.node.location, self.constant.toValue());

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        // var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Pattern\", \"constant\": \"__TODO_ESCAPE_QUOTES__\", ", .{}); //.{self.constant.string});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Pattern) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const StringNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .String,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    // List of nodes that will eventually be converted to strings concatened together
    elements: []*ParseNode,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        for (self.elements) |element| {
            if (!element.isConstant(element)) {
                return false;
            }
        }

        return true;
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            var list = std.ArrayList(*ObjString).init(gc.allocator);
            defer list.deinit();

            var str_value = std.ArrayList(u8).init(gc.allocator);
            var writer = str_value.writer();
            for (self.elements) |element| {
                assert(element.isConstant(element));

                try valueToString(writer, try element.toValue(element, gc));
            }

            return (try gc.copyString(str_value.items)).toValue();
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.elements.len == 0) {
            // Push the empty string which is always the constant 0
            try codegen.emitCodeArg(self.node.location, .OP_CONSTANT, 0);

            try node.endScope(codegen);

            return null;
        }

        for (self.elements) |element, index| {
            if (element.type_def == null or element.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(element.type_def.?.resolved_type.?.Placeholder);

                continue;
            }

            _ = try element.toByteCode(element, codegen, breaks);
            if (element.type_def.?.def_type != .String or element.type_def.?.optional) {
                try codegen.emitOpCode(self.node.location, .OP_TO_STRING);
            }

            if (index >= 1) {
                try codegen.emitOpCode(self.node.location, .OP_ADD);
            }
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"String\", \"elements\": [");

        for (self.elements) |element, i| {
            try element.toJson(element, out);

            if (i < self.elements.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return .{
            .elements = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.elements.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .String) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const NullNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Null,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    fn constant(_: *ParseNode) bool {
        return true;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return Value{ .Null = {} };
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        try codegen.emitOpCode(node.location, .OP_NULL);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        try out.writeAll("{\"node\": \"Null\", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Null) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ListNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .List,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    items: []*ParseNode,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        for (self.items) |item| {
            if (!item.isConstant(item)) {
                return false;
            }
        }

        return true;
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            assert(node.type_def != null and node.type_def.?.def_type != .Placeholder);

            var list = try gc.allocateObject(ObjList, _obj.ObjList.init(gc.allocator, node.type_def.?));

            for (self.items) |item| {
                try list.items.append(try item.toValue(item, gc));
            }

            return list.toValue();
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const item_type = self.node.type_def.?.resolved_type.?.List.item_type;
        const list_offset: usize = try codegen.emitList(self.node.location);

        for (self.items) |item| {
            if (item.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(item.type_def.?.resolved_type.?.Placeholder);
            } else if (!item_type.eql(item.type_def.?)) {
                try codegen.reportTypeCheckAt(item_type, item.type_def.?, "Bad list type", item.location);
            } else {
                _ = try item.toByteCode(item, codegen, breaks);

                try codegen.emitOpCode(item.location, .OP_LIST_APPEND);
            }
        }

        const list_type_constant: u24 = try codegen.makeConstant(Value{ .Obj = node.type_def.?.toObj() });
        try codegen.patchList(list_offset, list_type_constant);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"List\", \"items\": [");

        for (self.items) |item, i| {
            try item.toJson(item, out);

            if (i < self.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .List) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const MapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Map,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    keys: []*ParseNode,
    values: []*ParseNode,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        for (self.keys) |key| {
            if (!key.isConstant(key)) {
                return false;
            }
        }

        for (self.values) |value| {
            if (!value.isConstant(value)) {
                return false;
            }
        }

        return true;
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            assert(node.type_def != null and node.type_def.?.def_type != .Placeholder);

            var map = try gc.allocateObject(ObjMap, _obj.ObjMap.init(gc.allocator, node.type_def.?));

            assert(self.keys.len == self.values.len);

            for (self.keys) |key, index| {
                const value = self.values[index];
                try map.map.put(
                    _value.valueToHashable(try key.toValue(key, gc)),
                    try value.toValue(value, gc),
                );
            }

            return map.toValue();
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const key_type = self.node.type_def.?.resolved_type.?.Map.key_type;
        const value_type = self.node.type_def.?.resolved_type.?.Map.value_type;

        const map_offset: usize = try codegen.emitMap(self.node.location);

        assert(self.keys.len == self.values.len);

        for (self.keys) |key, i| {
            const value = self.values[i];

            _ = try key.toByteCode(key, codegen, breaks);
            _ = try value.toByteCode(value, codegen, breaks);

            try codegen.emitOpCode(self.node.location, .OP_SET_MAP);

            if (key.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(key.type_def.?.resolved_type.?.Placeholder);
            }

            if (value.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
            }

            if (!key_type.eql(key.type_def.?)) {
                try codegen.reportTypeCheckAt(key_type, key.type_def.?, "Bad key type", key.location);
            }

            if (!value_type.eql(value.type_def.?)) {
                try codegen.reportTypeCheckAt(value_type, value.type_def.?, "Bad value type", value.location);
            }
        }

        const map_type_constant: u24 = try codegen.makeConstant(Value{ .Obj = node.type_def.?.toObj() });
        try codegen.patchMap(map_offset, map_type_constant);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Map\", \"items\": [");

        for (self.keys) |key, i| {
            try out.writeAll("{\"key\":");

            try key.toJson(key, out);

            try out.writeAll(", \"value\": ");

            try self.values[i].toJson(self.values[i], out);

            try out.writeAll("}");

            if (i < self.keys.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Map) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const UnwrapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Unwrap,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    unwrapped: *ParseNode,
    original_type: ?*ObjTypeDef,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.unwrapped.isConstant(self.unwrapped);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            return try self.unwrapped.toValue(self.unwrapped, gc);
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.original_type == null or self.original_type.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.original_type.?.resolved_type.?.Placeholder);
        }

        if (!self.original_type.?.optional) {
            try codegen.reportErrorAt(self.unwrapped.location, "Not an optional.");
        }

        _ = try self.unwrapped.toByteCode(self.unwrapped, codegen, breaks);

        try codegen.emitOpCode(self.node.location, .OP_COPY);
        try codegen.emitOpCode(self.node.location, .OP_NULL);
        try codegen.emitOpCode(self.node.location, .OP_EQUAL);
        try codegen.emitOpCode(self.node.location, .OP_NOT);

        const jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);

        if (codegen.opt_jumps == null) {
            codegen.opt_jumps = std.ArrayList(usize).init(codegen.gc.allocator);
        }
        try codegen.opt_jumps.?.append(jump);

        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop test result

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Unwrap\", \"unwrapped\": ");

        try self.unwrapped.toJson(self.unwrapped, out);
        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Unwrap) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForceUnwrapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ForceUnwrap,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    unwrapped: *ParseNode,
    original_type: ?*ObjTypeDef,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.unwrapped.isConstant(self.unwrapped);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            const value = try self.unwrapped.toValue(self.unwrapped, gc);

            if (value == .Null) {
                return VM.Error.UnwrappedNull;
            }

            return value;
        }
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.original_type == null or self.original_type.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.original_type.?.resolved_type.?.Placeholder);

            return null;
        }

        if (!self.original_type.?.optional) {
            try codegen.reportErrorAt(self.unwrapped.location, "Not an optional.");
        }

        _ = try self.unwrapped.toByteCode(self.unwrapped, codegen, breaks);

        try codegen.emitOpCode(self.node.location, .OP_UNWRAP);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ForceUnwrap\", \"unwrapped\": ");

        try self.unwrapped.toJson(self.unwrapped, out);
        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ForceUnwrap) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const IsNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Is,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = cnts,
    },

    left: *ParseNode,
    constant: Value,

    fn cnts(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.left.isConstant(self.left);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;
            const left = try self.left.toValue(self.left, gc);

            return Value{ .Boolean = _value.valueIs(left, self.constant) };
        }
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        assert(self.constant == .Obj);
        assert(self.constant.Obj.obj_type == .Type);

        if (ObjTypeDef.cast(self.constant.Obj).?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(ObjTypeDef.cast(self.constant.Obj).?.resolved_type.?.Placeholder);
        }

        _ = try self.left.toByteCode(self.left, codegen, breaks);

        try codegen.emitCodeArg(self.node.location, .OP_CONSTANT, try codegen.makeConstant(self.constant));

        try codegen.emitOpCode(self.node.location, .OP_IS);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Is\", \"left\": ");

        try self.left.toJson(self.left, out);

        try out.writeAll(", \"constant\": \"");
        try valueToString(out, self.constant);
        try out.writeAll("\", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Is) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const UnaryNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Unary,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    left: *ParseNode,
    operator: TokenType,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.left.isConstant(self.left);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            const value = try self.left.toValue(self.left, gc);

            return switch (self.operator) {
                .Bnot => Value{ .Integer = ~(if (value == .Integer) value.Integer else @floatToInt(i64, value.Float)) },
                .Bang => Value{ .Boolean = !value.Boolean },
                .Minus => number: {
                    if (value == .Integer) {
                        break :number Value{ .Integer = -value.Integer };
                    } else {
                        break :number Value{ .Float = -value.Float };
                    }
                },
                else => unreachable,
            };
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.left.type_def == null or self.left.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.left.type_def.?.resolved_type.?.Placeholder);

            return null;
        }

        _ = try self.left.toByteCode(self.left, codegen, breaks);

        const left_type = self.left.type_def.?;
        switch (self.operator) {
            .Bnot => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorFmt(
                        self.left.location,
                        "Expected type `num`, got `{s}`",
                        .{try left_type.toStringAlloc(codegen.gc.allocator)},
                    );
                }

                try codegen.emitOpCode(self.node.location, .OP_BNOT);
            },
            .Bang => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorFmt(
                        self.left.location,
                        "Expected type `bool`, got `{s}`",
                        .{try left_type.toStringAlloc(codegen.gc.allocator)},
                    );
                }

                try codegen.emitOpCode(self.node.location, .OP_NOT);
            },
            .Minus => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorFmt(
                        self.left.location,
                        "Expected type `num`, got `{s}`",
                        .{try left_type.toStringAlloc(codegen.gc.allocator)},
                    );
                }

                try codegen.emitOpCode(self.node.location, .OP_NEGATE);
            },
            else => unreachable,
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Unary\", \"left\": ");

        try self.left.toJson(self.left, out);
        try out.print(", \"operator\": \"{}\", ", .{self.operator});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Unary) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BinaryNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Binary,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    left: *ParseNode,
    right: *ParseNode,
    operator: TokenType,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.left.isConstant(self.left) and self.right.isConstant(self.right);
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            var left = floatToInteger(try self.left.toValue(self.left, gc));
            var right = floatToInteger(try self.right.toValue(self.right, gc));
            var left_f: ?f64 = if (left == .Float) left.Float else null;
            var right_f: ?f64 = if (right == .Float) right.Float else null;
            var left_i: ?i64 = if (left == .Integer) left.Integer else null;
            var right_i: ?i64 = if (right == .Integer) right.Integer else null;

            switch (self.operator) {
                .Ampersand => {
                    return Value{
                        .Integer = (left_i orelse @floatToInt(i64, left_f.?)) & (right_i orelse @floatToInt(i64, right_f.?)),
                    };
                },
                .Bor => {
                    return Value{
                        .Integer = (left_i orelse @floatToInt(i64, left_f.?)) | (right_i orelse @floatToInt(i64, right_f.?)),
                    };
                },
                .Xor => {
                    return Value{
                        .Integer = (left_i orelse @floatToInt(i64, left_f.?)) ^ (right_i orelse @floatToInt(i64, right_f.?)),
                    };
                },
                .ShiftLeft => {
                    const b = right_i orelse @floatToInt(i64, right_f.?);

                    if (b < 0) {
                        if (b * -1 > std.math.maxInt(u6)) {
                            return Value{ .Integer = 0 };
                        }

                        return Value{
                            .Integer = (left_i orelse @floatToInt(i64, left_f.?)) >> @truncate(u6, @intCast(u64, b * -1)),
                        };
                    } else {
                        if (b > std.math.maxInt(u6)) {
                            return Value{ .Integer = 0 };
                        }

                        return Value{
                            .Integer = (left_i orelse @floatToInt(i64, left_f.?)) << @truncate(u6, @intCast(u64, b)),
                        };
                    }
                },
                .ShiftRight => {
                    const b = right_i orelse @floatToInt(i64, right_f.?);

                    if (b < 0) {
                        if (b * -1 > std.math.maxInt(u6)) {
                            return Value{ .Integer = 0 };
                        }

                        return Value{
                            .Integer = (left_i orelse @floatToInt(i64, left_f.?)) << @truncate(u6, @intCast(u64, b * -1)),
                        };
                    } else {
                        if (b > std.math.maxInt(u6)) {
                            return Value{ .Integer = 0 };
                        }

                        return Value{
                            .Integer = (left_i orelse @floatToInt(i64, left_f.?)) >> @truncate(u6, @intCast(u64, b)),
                        };
                    }
                },
                .QuestionQuestion => {
                    if (left == .Null) {
                        return right;
                    }

                    return left;
                },
                .Greater => {
                    if (left_f) |lf| {
                        if (right_f) |rf| {
                            return Value{ .Boolean = lf > rf };
                        } else {
                            return Value{ .Boolean = lf > @intToFloat(f64, right_i.?) };
                        }
                    } else {
                        if (right_f) |rf| {
                            return Value{ .Boolean = @intToFloat(f64, left_i.?) > rf };
                        } else {
                            return Value{ .Boolean = left_i.? > right_i.? };
                        }
                    }
                    return Value{ .Boolean = (left_f orelse left_i.?) > (right_f orelse right_i.?) };
                },
                .Less => {
                    if (left_f) |lf| {
                        if (right_f) |rf| {
                            return Value{ .Boolean = lf < rf };
                        } else {
                            return Value{ .Boolean = lf < @intToFloat(f64, right_i.?) };
                        }
                    } else {
                        if (right_f) |rf| {
                            return Value{ .Boolean = @intToFloat(f64, left_i.?) < rf };
                        } else {
                            return Value{ .Boolean = left_i.? < right_i.? };
                        }
                    }
                    return Value{ .Boolean = (left_f orelse left_i.?) < (right_f orelse right_i.?) };
                },
                .GreaterEqual => {
                    if (left_f) |lf| {
                        if (right_f) |rf| {
                            return Value{ .Boolean = lf >= rf };
                        } else {
                            return Value{ .Boolean = lf >= @intToFloat(f64, right_i.?) };
                        }
                    } else {
                        if (right_f) |rf| {
                            return Value{ .Boolean = @intToFloat(f64, left_i.?) >= rf };
                        } else {
                            return Value{ .Boolean = left_i.? >= right_i.? };
                        }
                    }
                    return Value{ .Boolean = (left_f orelse left_i.?) >= (right_f orelse right_i.?) };
                },
                .LessEqual => {
                    if (left_f) |lf| {
                        if (right_f) |rf| {
                            return Value{ .Boolean = lf <= rf };
                        } else {
                            return Value{ .Boolean = lf <= @intToFloat(f64, right_i.?) };
                        }
                    } else {
                        if (right_f) |rf| {
                            return Value{ .Boolean = @intToFloat(f64, left_i.?) <= rf };
                        } else {
                            return Value{ .Boolean = left_i.? <= right_i.? };
                        }
                    }
                    return Value{ .Boolean = (left_f orelse left_i.?) <= (right_f orelse right_i.?) };
                },
                .BangEqual => {
                    return Value{ .Boolean = !_value.valueEql(left, right) };
                },
                .EqualEqual => {
                    return Value{ .Boolean = _value.valueEql(left, right) };
                },
                .Plus => {
                    const right_s: ?*ObjString = if (right == .Obj) ObjString.cast(right.Obj) else null;
                    const left_s: ?*ObjString = if (left == .Obj) ObjString.cast(left.Obj) else null;

                    const right_l: ?*ObjList = if (right == .Obj) ObjList.cast(right.Obj) else null;
                    const left_l: ?*ObjList = if (left == .Obj) ObjList.cast(left.Obj) else null;

                    const right_m: ?*ObjMap = if (right == .Obj) ObjMap.cast(right.Obj) else null;
                    const left_m: ?*ObjMap = if (left == .Obj) ObjMap.cast(left.Obj) else null;

                    if (right_s != null) {
                        var new_string: std.ArrayList(u8) = std.ArrayList(u8).init(gc.allocator);
                        try new_string.appendSlice(left_s.?.string);
                        try new_string.appendSlice(right_s.?.string);

                        return (try gc.copyString(new_string.items)).toValue();
                    } else if (right_f != null or left_f != null) {
                        return Value{
                            .Float = (right_f orelse @intToFloat(f64, right_i.?)) + (left_f orelse @intToFloat(f64, left_i.?)),
                        };
                    } else if (right_i != null or left_i != null) {
                        return Value{
                            .Integer = right_i.? + left_i.?,
                        };
                    } else if (right_l != null) {
                        var new_list = std.ArrayList(Value).init(gc.allocator);
                        try new_list.appendSlice(left_l.?.items.items);
                        try new_list.appendSlice(right_l.?.items.items);

                        var list = try gc.allocateObject(
                            ObjList,
                            ObjList{
                                .type_def = left_l.?.type_def,
                                .methods = left_l.?.methods,
                                .items = new_list,
                            },
                        );

                        return list.toValue();
                    }

                    // map
                    var new_map = try right_m.?.map.clone();
                    var it = left_m.?.map.iterator();
                    while (it.next()) |entry| {
                        try new_map.put(entry.key_ptr.*, entry.value_ptr.*);
                    }

                    var map = try gc.allocateObject(
                        ObjMap,
                        ObjMap{
                            .type_def = left_m.?.type_def,
                            .methods = left_m.?.methods,
                            .map = new_map,
                        },
                    );

                    return map.toValue();
                },
                .Minus => {
                    if (right_f != null or left_f != null) {
                        return Value{ .Float = (right_f orelse @intToFloat(f64, right_i.?)) - (left_f orelse @intToFloat(f64, left_i.?)) };
                    }

                    return Value{ .Integer = right_i.? - left_i.? };
                },
                .Star => {
                    if (right_f != null or left_f != null) {
                        return Value{ .Float = (right_f orelse @intToFloat(f64, right_i.?)) * (left_f orelse @intToFloat(f64, left_i.?)) };
                    }

                    return Value{ .Integer = right_i.? * left_i.? };
                },
                .Slash => {
                    if (right_f != null or left_f != null) {
                        return Value{ .Float = (right_f orelse @intToFloat(f64, right_i.?)) / (left_f orelse @intToFloat(f64, left_i.?)) };
                    }

                    return Value{ .Float = @intToFloat(f64, right_i.?) / @intToFloat(f64, left_i.?) };
                },
                .Percent => {
                    if (right_f != null or left_f != null) {
                        return Value{ .Float = @mod((right_f orelse @intToFloat(f64, right_i.?)), (left_f orelse @intToFloat(f64, left_i.?))) };
                    }

                    return Value{ .Integer = @mod(right_i.?, left_i.?) };
                },
                .And => {
                    return Value{ .Boolean = left.Boolean and right.Boolean };
                },
                .Or => {
                    return Value{ .Boolean = left.Boolean or right.Boolean };
                },
                else => unreachable,
            }
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const left_type = self.left.type_def.?;
        const right_type = self.right.type_def.?;

        if (self.left.type_def == null or self.left.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.left.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.right.type_def == null or self.right.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.right.type_def.?.resolved_type.?.Placeholder);
        }

        if (!left_type.eql(right_type)) {
            try codegen.reportTypeCheckAt(left_type, right_type, "Type mismatch", node.location);
        }

        switch (self.operator) {
            .QuestionQuestion => {
                if (!left_type.optional) {
                    try codegen.reportErrorAt(node.location, "Not an optional");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_NULL_OR);
            },
            .Ampersand => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_BAND);
            },
            .Bor => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_BOR);
            },
            .Xor => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_XOR);
            },
            .ShiftLeft => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_SHL);
            },
            .ShiftRight => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_SHR);
            },
            .Greater => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_GREATER);
            },
            .Less => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_LESS);
            },
            .GreaterEqual => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_LESS);
                try codegen.emitOpCode(self.node.location, .OP_NOT);
            },
            .LessEqual => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_GREATER);
                try codegen.emitOpCode(self.node.location, .OP_NOT);
            },
            .BangEqual => {
                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_EQUAL);
                try codegen.emitOpCode(self.node.location, .OP_NOT);
            },
            .EqualEqual => {
                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_EQUAL);
            },
            .Plus => {
                // zig fmt: off
                if (left_type.def_type != .Number
                    and left_type.def_type != .String
                    and left_type.def_type != .List
                    and left_type.def_type != .Map) {
                    try codegen.reportErrorAt(self.left.location, "Expected a `num`, `str`, list or map.");
                }
                // zig fmt: on

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_ADD);
            },
            .Minus => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_SUBTRACT);
            },
            .Star => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_MULTIPLY);
            },
            .Slash => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_DIVIDE);
            },
            .Percent => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);
                _ = try self.right.toByteCode(self.right, codegen, breaks);
                try codegen.emitOpCode(self.node.location, .OP_MOD);
            },
            .And => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorAt(node.location, "`and` expects operands to be `bool`");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);

                const end_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
                try codegen.emitOpCode(self.node.location, .OP_POP);

                _ = try self.right.toByteCode(self.right, codegen, breaks);

                try codegen.patchJump(end_jump);
            },
            .Or => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorAt(node.location, "`and` expects operands to be `bool`");
                }

                _ = try self.left.toByteCode(self.left, codegen, breaks);

                const else_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
                const end_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP);

                try codegen.patchJump(else_jump);
                try codegen.emitOpCode(self.node.location, .OP_POP);

                _ = try self.right.toByteCode(self.right, codegen, breaks);

                try codegen.patchJump(end_jump);
            },
            else => unreachable,
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Binary\", \"left\": ");

        try self.left.toJson(self.left, out);
        try out.print(", \"operator\": \"{}\", \"right\": ", .{self.operator});
        try self.right.toJson(self.right, out);
        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Binary) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const SubscriptNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Subscript,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    subscripted: *ParseNode,
    index: *ParseNode,
    value: ?*ParseNode,

    fn constant(node: *ParseNode) bool {
        const self = Self.cast(node).?;

        return self.subscripted.isConstant(self.subscripted) and self.index.isConstant(self.index) and self.value == null;
    }

    fn val(node: *ParseNode, gc: *GarbageCollector) anyerror!Value {
        if (node.isConstant(node)) {
            const self = Self.cast(node).?;

            const subscriptable = (try self.subscripted.toValue(self.subscripted, gc)).Obj;
            const index = floatToInteger(try self.index.toValue(self.index, gc));

            switch (subscriptable.obj_type) {
                .List => {
                    const list: *ObjList = ObjList.cast(subscriptable).?;

                    const list_index_i: ?i64 = if (index == .Integer) index.Integer else null;

                    if (list_index_i == null or list_index_i.? < 0) {
                        return VM.Error.OutOfBound;
                    }

                    const list_index: usize = @intCast(usize, list_index_i.?);

                    if (list_index < list.items.items.len) {
                        return list.items.items[list_index];
                    } else {
                        return VM.Error.OutOfBound;
                    }
                },
                .Map => {
                    const map: *ObjMap = ObjMap.cast(subscriptable).?;

                    if (map.map.get(_value.valueToHashable(index))) |value| {
                        return value;
                    } else {
                        return Value{ .Null = {} };
                    }
                },
                .String => {
                    const str: *ObjString = ObjString.cast(subscriptable).?;

                    const str_index_i: ?i64 = if (index == .Integer) index.Integer else null;

                    if (str_index_i == null or str_index_i.? < 0) {
                        return VM.Error.OutOfBound;
                    }

                    const str_index: usize = @intCast(usize, str_index_i.?);

                    if (str_index < str.string.len) {
                        return (try gc.copyString(&([_]u8{str.string[str_index]}))).toValue();
                    } else {
                        return VM.Error.OutOfBound;
                    }
                },
                else => unreachable,
            }
        }

        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.subscripted.toByteCode(self.subscripted, codegen, breaks);

        if (self.subscripted.type_def == null or self.subscripted.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.subscripted.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.index.type_def == null or self.index.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.index.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.value != null and (self.value.?.type_def == null or self.value.?.type_def.?.def_type == .Placeholder)) {
            try codegen.reportPlaceholder(self.value.?.type_def.?.resolved_type.?.Placeholder);
        }

        switch (self.subscripted.type_def.?.def_type) {
            .String => {
                if (self.index.type_def.?.def_type != .Number) {
                    try codegen.reportErrorAt(self.index.location, "Expected `num` index.");
                }

                assert(self.value == null);
            },
            .List => {
                if (self.index.type_def.?.def_type != .Number) {
                    try codegen.reportErrorAt(self.index.location, "Expected `num` index.");
                }

                if (self.value) |value| {
                    if (!self.subscripted.type_def.?.resolved_type.?.List.item_type.eql(value.type_def.?)) {
                        try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.List.item_type, value.type_def.?, "Bad value type", value.location);
                    }
                }
            },
            .Map => {
                if (!self.subscripted.type_def.?.resolved_type.?.Map.key_type.eql(self.index.type_def.?)) {
                    try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.Map.key_type, self.index.type_def.?, "Bad key type", self.index.location);
                }

                if (self.value) |value| {
                    if (!self.subscripted.type_def.?.resolved_type.?.Map.value_type.eql(value.type_def.?)) {
                        try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.Map.value_type, value.type_def.?, "Bad value type", value.location);
                    }
                }
            },
            else => try codegen.reportErrorAt(node.location, "Not subscriptable."),
        }

        _ = try self.index.toByteCode(self.index, codegen, breaks);

        if (self.value) |value| {
            _ = try value.toByteCode(value, codegen, breaks);

            try codegen.emitOpCode(self.node.location, .OP_SET_SUBSCRIPT);
        } else {
            try codegen.emitOpCode(self.node.location, .OP_GET_SUBSCRIPT);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Subscript\", \"subscripted\": ");

        try self.subscripted.toJson(self.subscripted, out);

        try out.writeAll(", \"index\": ");

        try self.index.toJson(self.index, out);

        try out.writeAll(", ");

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Subscript) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const TryNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Try,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    body: *ParseNode,
    clauses: std.AutoArrayHashMap(*ObjTypeDef, *ParseNode),
    unconditional_clause: ?*ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        const self = Self.cast(node).?;

        codegen.current.?.try_should_handle = std.AutoHashMap(*ObjTypeDef, void).init(codegen.gc.allocator);
        defer {
            codegen.current.?.try_should_handle.?.deinit();
            codegen.current.?.try_should_handle = null;
        }

        // OP_TRY notifies runtime that we're handling error at offset
        const try_jump = try codegen.emitJump(node.location, .OP_TRY);

        _ = try self.body.toByteCode(self.body, codegen, breaks);

        // Jump reached if no error was raised
        const no_error_jump = try codegen.emitJump(self.body.end_location, .OP_JUMP);

        var exit_jumps = std.ArrayList(usize).init(codegen.gc.allocator);
        defer exit_jumps.deinit();

        try codegen.patchTry(try_jump);
        for (self.clauses.keys()) |error_type| {
            const clause = self.clauses.get(error_type).?;

            // We assume the error is on top of the stack
            try codegen.emitOpCode(clause.location, .OP_COPY); // Copy error value since its argument to the catch clause
            try codegen.emitConstant(clause.location, error_type.toValue());
            try codegen.emitOpCode(clause.location, .OP_IS);
            // If error type does not match, jump to next catch clause
            const next_clause_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
            // Pop `is` result
            try codegen.emitOpCode(clause.location, .OP_POP);

            // Clause block will pop error value since its declared as a local in it
            // We don't catch things is the catch clause
            const previous = codegen.current.?.try_should_handle;
            codegen.current.?.try_should_handle = null;
            _ = try clause.toByteCode(clause, codegen, breaks);
            codegen.current.?.try_should_handle = previous;

            // After handling the error, jump over next clauses
            try exit_jumps.append(try codegen.emitJump(self.node.location, .OP_JUMP));

            try codegen.patchJump(next_clause_jump);
            // Pop `is` result
            try codegen.emitOpCode(clause.location, .OP_POP);
        }

        if (self.unconditional_clause) |unconditional_clause| {
            // pop error because its not a local of this clause
            try codegen.emitOpCode(unconditional_clause.location, .OP_POP);
            // We don't catch things is the catch clause
            const previous = codegen.current.?.try_should_handle;
            codegen.current.?.try_should_handle = null;
            _ = try unconditional_clause.toByteCode(unconditional_clause, codegen, breaks);
            codegen.current.?.try_should_handle = previous;

            try exit_jumps.append(try codegen.emitJump(self.node.location, .OP_JUMP));
        }

        // Tell runtime we're not in a try block anymore
        try codegen.emitOpCode(node.location, .OP_TRY_END);
        // Uncaught error, throw the error again
        try codegen.emitOpCode(node.location, .OP_THROW);

        // Patch exit jumps
        for (exit_jumps.items) |exit_jump| {
            try codegen.patchJump(exit_jump);
        }

        try codegen.patchJump(no_error_jump);

        // OP_TRY_END notifies runtime that we're not in a try block anymore
        try codegen.emitOpCode(node.location, .OP_TRY_END);

        // Did we handle all errors not specified in current function signature?
        var it = codegen.current.?.try_should_handle.?.iterator();
        while (it.next()) |kv| {
            if (self.unconditional_clause == null and self.clauses.get(kv.key_ptr.*) == null) {
                const err_str = try kv.key_ptr.*.toStringAlloc(codegen.gc.allocator);
                defer codegen.gc.allocator.free(err_str);

                try codegen.reportErrorFmt(node.location, "Error type `{s}` not handled", .{err_str});
            }
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Try\", ", .{});

        try ParseNode.stringify(node, out);

        try out.writeAll(",\"body\": ");

        try self.body.toJson(self.body, out);

        try out.writeAll(",\"unconditional_clause\": ");

        if (self.unconditional_clause) |clause| {
            try clause.toJson(clause, out);
        } else {
            try out.writeAll("null");
        }

        try out.writeAll(",\"clauses\": {");
        // TODO
        try out.writeAll("}");

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Try) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const FunctionNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Function,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    body: ?*BlockNode = null,
    arrow_expr: ?*ParseNode = null,
    native: ?*ObjNative = null,
    test_message: ?*ParseNode = null,
    // If true this is the root of a script being imported
    import_root: bool = false,
    upvalue_binding: std.AutoArrayHashMap(u8, bool),

    // Useful when generating root script bootstrap code
    main_slot: ?usize = null,
    test_slots: ?[]usize = null,
    exported_count: ?usize = null,

    fn constant(_: *ParseNode) bool {
        // TODO: should be true but requires to codegen the node
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        var enclosing = codegen.current;
        codegen.current = try codegen.gc.allocator.create(Frame);
        codegen.current.?.* = Frame{
            .enclosing = enclosing,
            .function_node = self,
        };

        var function = try ObjFunction.init(
            codegen.gc.allocator,
            node.type_def.?.resolved_type.?.Function.name,
        );

        function.type_def = node.type_def.?;

        // Check for any remaining placeholders in function signature
        if (function.type_def.def_type == .Placeholder) {
            try codegen.reportPlaceholder(function.type_def.resolved_type.?.Placeholder);
        } else {
            const function_def = function.type_def.resolved_type.?.Function;

            if (function_def.return_type.def_type == .Placeholder) {
                try codegen.reportPlaceholder(function_def.return_type.resolved_type.?.Placeholder);
            }

            if (function_def.yield_type.def_type == .Placeholder) {
                try codegen.reportPlaceholder(function_def.yield_type.resolved_type.?.Placeholder);
            }

            var it = function_def.parameters.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.*.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(kv.value_ptr.*.resolved_type.?.Placeholder);
                }
            }

            if (function_def.error_types) |error_types| {
                for (error_types) |error_type| {
                    if (error_type.def_type == .Placeholder) {
                        try codegen.reportPlaceholder(error_type.resolved_type.?.Placeholder);
                    }
                }
            }
        }

        // First chunk constant is the empty string
        _ = try function.chunk.addConstant(null, Value{
            .Obj = (try codegen.gc.copyString("")).toObj(),
        });

        codegen.current.?.function = try codegen.gc.allocateObject(ObjFunction, function);

        const function_type = node.type_def.?.resolved_type.?.Function.function_type;

        // Can't have both arrow expression and body
        assert((self.arrow_expr != null and self.body == null) or (self.arrow_expr == null and self.body != null));

        // Generate function's body bytecode
        if (self.arrow_expr) |arrow_expr| {
            _ = try arrow_expr.toByteCode(arrow_expr, codegen, breaks);
            try codegen.emitOpCode(arrow_expr.location, .OP_RETURN);
            codegen.current.?.return_emitted = true;
        } else {
            _ = try self.body.?.node.toByteCode(&self.body.?.node, codegen, breaks);
        }

        if (function_type != .Extern) {
            // If .Script, search for exported globals and return them in a map
            if (function_type == .Script or function_type == .ScriptEntryPoint) {
                // If top level, search `main` or `test` function(s) and call them
                // Then put any exported globals on the stack
                if (!codegen.testing and function_type == .ScriptEntryPoint) {
                    if (self.main_slot) |main_slot| {
                        try codegen.emitCodeArg(node.location, .OP_GET_GLOBAL, @intCast(u24, main_slot));
                        try codegen.emitCodeArg(node.location, .OP_GET_LOCAL, 0); // cli args are always local 0
                        try codegen.emitCodeArgs(node.location, .OP_CALL, 1, 0);
                    }
                } else if (codegen.testing and self.test_slots != null) {
                    // Create an entry point wich runs all `test`
                    for (self.test_slots.?) |slot| {
                        try codegen.emitCodeArg(node.location, .OP_GET_GLOBAL, @intCast(u24, slot));
                        try codegen.emitCodeArgs(node.location, .OP_CALL, 0, 0);
                    }
                }

                // If we're being imported, put all globals on the stack
                if (self.import_root) {
                    if (self.exported_count orelse 0 > 16777215) {
                        try codegen.reportErrorAt(node.location, "Can't export more than 16777215 values.");
                    }

                    var index: usize = 0;
                    while (index < self.exported_count orelse 0) : (index += 1) {
                        try codegen.emitCodeArg(node.location, .OP_GET_GLOBAL, @intCast(u24, index));
                    }

                    try codegen.emitCodeArg(node.location, .OP_EXPORT, @intCast(u24, self.exported_count orelse 0));
                } else {
                    try codegen.emitOpCode(node.location, .OP_VOID);
                    try codegen.emitOpCode(node.location, .OP_RETURN);
                    codegen.current.?.return_emitted = true;
                }
            } else if (codegen.current.?.function.?.type_def.resolved_type.?.Function.return_type.def_type == .Void and !codegen.current.?.return_emitted) {
                // TODO: detect if some branches of the function body miss a return statement
                try codegen.emitReturn(node.location);
            } else if (!codegen.current.?.return_emitted) {
                try codegen.reportErrorAt(node.location, "Missing return statement");
            }
        }

        var frame = codegen.current.?;
        var current_function: *ObjFunction = frame.function.?;
        current_function.upvalue_count = @intCast(u8, self.upvalue_binding.count());

        if (Config.debug) {
            try disassembleChunk(&current_function.chunk, current_function.name.string);
            std.debug.print("\n\n", .{});
        }

        codegen.current = frame.enclosing;

        if (function_type != .ScriptEntryPoint) {
            // `extern` functions don't have upvalues
            if (function_type == .Extern) {
                try codegen.emitCodeArg(node.location, .OP_CONSTANT, try codegen.makeConstant(self.native.?.toValue()));
            } else {
                try codegen.emitCodeArg(node.location, .OP_CLOSURE, try codegen.makeConstant(current_function.toValue()));

                var it = self.upvalue_binding.iterator();
                while (it.next()) |kv| {
                    try codegen.emit(node.location, if (kv.value_ptr.*) 1 else 0);
                    try codegen.emit(node.location, kv.key_ptr.*);
                }
            }
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return current_function;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print(
            "{{\"node\": \"Function\", \"type\": \"{}\", \"name\": \"{s}\", ",
            .{
                self.node.type_def.?.resolved_type.?.Function.function_type,
                self.node.type_def.?.resolved_type.?.Function.name.string,
            },
        );

        if (self.body) |body| {
            try out.writeAll("\"body\": ");

            try body.toNode().toJson(body.toNode(), out);
        } else if (self.arrow_expr) |expr| {
            try out.writeAll("\"arrow_expr\": ");

            try expr.toJson(expr, out);
        }

        try out.writeAll(", ");

        if (self.native) |native| {
            try out.writeAll("\"native\": \"");

            try valueToString(out, native.toValue());

            try out.writeAll("\",");
        }

        if (self.test_message) |test_message| {
            try out.writeAll("\"test_message\": ");
            try test_message.toJson(test_message, out);

            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(parser: *Parser, function_type: FunctionType, script_name: []const u8, name: ?[]const u8) !Self {
        var self = Self{
            .body = try parser.gc.allocator.create(BlockNode),
            .upvalue_binding = std.AutoArrayHashMap(u8, bool).init(parser.gc.allocator),
        };

        self.body.?.* = BlockNode.init(parser.gc.allocator);

        const function_name: []const u8 = switch (function_type) {
            .EntryPoint => "main",
            .ScriptEntryPoint, .Script => name orelse script_name,
            else => name orelse "???",
        };

        const function_def = ObjFunction.FunctionDef{
            .name = try parser.gc.copyString(function_name),
            .script_name = try parser.gc.copyString(script_name),
            .return_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
            .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
            .parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator),
            .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
            .function_type = function_type,
        };

        const type_def = ObjTypeDef.TypeUnion{ .Function = function_def };

        self.node.type_def = try parser.gc.type_registry.getTypeDef(
            .{
                .def_type = .Function,
                .resolved_type = type_def,
            },
        );

        return self;
    }

    pub fn deinit(self: Self) void {
        self.body.deinit();
        self.default_arguments.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Function) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const YieldNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Yield,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    expression: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?; // self

        const current_function_typedef = codegen.current.?.function_node.node.type_def.?.resolved_type.?.Function;
        const current_function_type = current_function_typedef.function_type;
        switch (current_function_type) {
            .Script,
            .ScriptEntryPoint,
            .EntryPoint,
            .Test,
            .Extern,
            => try codegen.reportErrorAt(node.location, "Can't yield here"),
            else => {},
        }

        if (node.type_def == null) {
            try codegen.reportErrorAt(node.location, "Unknown type.");
        } else if (node.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(node.type_def.?.resolved_type.?.Placeholder);
        } else if (!codegen.current.?.function.?.type_def.resolved_type.?.Function.yield_type.eql(node.type_def.?)) {
            try codegen.reportTypeCheckAt(
                codegen.current.?.function.?.type_def.resolved_type.?.Function.yield_type,
                node.type_def.?,
                "Bad yield value",
                node.location,
            );
        }

        _ = try self.expression.toByteCode(self.expression, codegen, breaks);

        try codegen.emitOpCode(node.location, .OP_YIELD);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        const self = Self.cast(node).?; // self

        try out.writeAll("{\"node\": \"Yield\", \"expression\": ");

        try self.expression.toJson(self.expression, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Yield) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ResolveNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Resolve,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    fiber: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?; // self

        if (self.fiber.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.fiber.type_def.?.resolved_type.?.Placeholder);

            return null;
        }

        if (self.fiber.type_def.?.def_type != .Fiber) {
            try codegen.report(self.fiber.location, "Not a fiber");
        }

        _ = try self.fiber.toByteCode(self.fiber, codegen, breaks);

        try codegen.emitOpCode(node.location, .OP_RESOLVE);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        const self = Self.cast(node).?; // self

        try out.writeAll("{\"node\": \"Resolve\", \"fiber\": ");

        try self.fiber.toJson(self.fiber, out);

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Resolve) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ResumeNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Resume,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    fiber: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?; // self

        if (self.fiber.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.fiber.type_def.?.resolved_type.?.Placeholder);

            return null;
        }

        if (self.fiber.type_def.?.def_type != .Fiber) {
            try codegen.report(self.fiber.location, "Not a fiber");
        }

        _ = try self.fiber.toByteCode(self.fiber, codegen, breaks);

        try codegen.emitOpCode(node.location, .OP_RESUME);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        const self = Self.cast(node).?; // self

        try out.writeAll("{\"node\": \"Resume\", \"fiber\": ");

        try self.fiber.toJson(self.fiber, out);

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Resume) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const AsyncCallNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .AsyncCall,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    call: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?; // self

        // Push fiber type as constant (we only need it if the fiber is printed out)
        // Should not interfere with local counts since OP_ROUTINE will consume it right away
        try codegen.emitConstant(
            node.location,
            node.type_def.?.toValue(),
        );

        _ = try self.call.toByteCode(self.call, codegen, breaks);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        const self = Self.cast(node).?; // self

        try out.writeAll("{\"node\": \"AsyncCall\", \"call\": ");

        try self.call.toJson(self.call, out);

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .AsyncCall) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const CallNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Call,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    async_call: bool = false,
    callee: *ParseNode,
    callable_type: ?*ObjTypeDef,
    arguments: std.AutoArrayHashMap(*ObjString, *ParseNode),
    catch_default: ?*ParseNode = null,
    super: ?*NamedVariableNode = null,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.callee.type_def == null or self.callee.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.callee.type_def.?.resolved_type.?.Placeholder);
        }

        // This is not a call but an Enum(value)
        if (self.callee.type_def.?.def_type == .Enum) {
            if (self.async_call) {
                try codegen.reportErrorAt(self.callee.end_location, "Can't be wrapped in a fiber");
            }

            if (self.catch_default != null) {
                try codegen.reportErrorAt(self.callee.end_location, "Doesn't raise any error");
            }

            if (self.arguments.count() > 1) {
                try codegen.reportErrorAt(self.callee.end_location, "Enum instanciation expect only value");
            } else if (self.arguments.count() == 0) {
                try codegen.reportErrorAt(self.callee.end_location, "Enum instanciation expect value");

                return null;
            }

            const value = self.arguments.get(self.arguments.keys()[0]).?;

            if (value.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
            }

            _ = try self.callee.toByteCode(self.callee, codegen, breaks);
            _ = try value.toByteCode(value, codegen, breaks);
            try codegen.emitOpCode(value.location, .OP_GET_ENUM_CASE_FROM_VALUE);

            return null;
        }

        // Find out if call is invoke or regular call
        var invoked = false;
        var invoked_on: ?ObjTypeDef.Type = null;

        if (self.callee.node_type == .Dot) {
            const dot = DotNode.cast(self.callee).?;
            const field_accessed = dot.callee.type_def;

            if (field_accessed == null or field_accessed.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(field_accessed.?.resolved_type.?.Placeholder);
            }

            invoked = field_accessed.?.def_type != .Object;
            invoked_on = field_accessed.?.def_type;
        }

        if (!invoked and self.super == null and invoked_on == null) {
            _ = try self.callee.toByteCode(self.callee, codegen, breaks);
        }

        const callee_type = switch (self.callee.node_type) {
            .Dot => DotNode.cast(self.callee).?.member_type_def,
            .Super => SuperNode.cast(self.callee).?.member_type_def,
            else => self.callee.type_def,
        };

        if (callee_type == null or callee_type.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(callee_type.?.resolved_type.?.Placeholder);

            // We know nothing about the function being called, no need to go any further
            return null;
        } else if (callee_type.?.def_type != .Function) {
            try codegen.report(self.node.location, "Can't be called");

            return null;
        }

        // Function being called and current function should have matching yield type unless the current function is an entrypoint
        const current_function_typedef = codegen.current.?.function_node.node.type_def.?.resolved_type.?.Function;
        const current_function_type = current_function_typedef.function_type;
        const current_function_yield_type = current_function_typedef.yield_type;
        const yield_type = callee_type.?.resolved_type.?.Function.yield_type;
        switch (current_function_type) {
            // Event though a function can call a yieldable function without wraping it in a fiber, the function itself could be called in a fiber
            .Function, .Method, .Anonymous => {
                if (!current_function_yield_type.eql(yield_type)) {
                    try codegen.reportTypeCheckAt(current_function_yield_type, yield_type, "Bad function yield type", node.location);
                }
            },
            else => {},
        }

        // Arguments
        const args: std.AutoArrayHashMap(*ObjString, *ObjTypeDef) = callee_type.?.resolved_type.?.Function.parameters;
        const defaults = callee_type.?.resolved_type.?.Function.defaults;
        const arg_keys = args.keys();
        const arg_count = arg_keys.len;

        var missing_arguments = std.AutoArrayHashMap(*ObjString, usize).init(codegen.gc.allocator);
        defer missing_arguments.deinit();
        for (arg_keys) |arg_name, pindex| {
            try missing_arguments.put(arg_name, pindex);
        }

        if (self.arguments.count() > args.count()) {
            try codegen.reportErrorAt(node.location, "Too many arguments.");
        }

        // First push on the stack arguments has they are parsed
        var needs_reorder = false;
        for (self.arguments.keys()) |arg_key, index| {
            const argument = self.arguments.get(arg_key).?;
            const actual_arg_key = if (index == 0 and std.mem.eql(u8, arg_key.string, "$")) arg_keys[0] else arg_key;
            const def_arg_type = args.get(actual_arg_key);

            const ref_index = args.getIndex(actual_arg_key);
            if (index != ref_index) {
                needs_reorder = true;
            }

            // Type check the argument
            if (def_arg_type) |arg_type| {
                if (argument.type_def == null or argument.type_def.?.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(argument.type_def.?.resolved_type.?.Placeholder);
                } else if (!arg_type.eql(argument.type_def.?)) {
                    try codegen.reportTypeCheckAt(
                        arg_type,
                        argument.type_def.?,
                        "Bad argument type",
                        argument.location,
                    );
                }

                _ = missing_arguments.orderedRemove(actual_arg_key);
            } else {
                try codegen.reportErrorFmt(argument.location, "Argument `{s}` does not exists.", .{arg_key.string});
            }

            _ = try argument.toByteCode(argument, codegen, breaks);
        }

        // Argument order reference
        var arguments_order_ref = std.ArrayList(*ObjString).init(codegen.gc.allocator);
        defer arguments_order_ref.deinit();
        try arguments_order_ref.appendSlice(self.arguments.keys());

        // Push default arguments
        if (missing_arguments.count() > 0) {
            var tmp_missing_arguments = try missing_arguments.clone();
            defer tmp_missing_arguments.deinit();
            const missing_keys = tmp_missing_arguments.keys();
            for (missing_keys) |missing_key| {
                if (defaults.get(missing_key)) |default| {
                    // TODO: like ObjTypeDef, avoid generating constants multiple time for the same value
                    try codegen.emitConstant(node.location, default);
                    try codegen.emitOpCode(node.location, .OP_CLONE);

                    try arguments_order_ref.append(missing_key);
                    _ = missing_arguments.orderedRemove(missing_key);
                    needs_reorder = true;
                }
            }
        }

        if (missing_arguments.count() > 0) {
            var missing = std.ArrayList(u8).init(codegen.gc.allocator);
            const missing_writer = missing.writer();
            for (missing_arguments.keys()) |key| {
                try missing_writer.print("{s}, ", .{key.string});
            }
            defer missing.deinit();
            try codegen.reportErrorFmt(node.location, "Missing argument(s): {s}", .{missing.items});
        }

        // Reorder arguments
        if (needs_reorder) {
            // Until ordered
            while (true) {
                var ordered = true;

                for (arguments_order_ref.items) |arg_key, index| {
                    const actual_arg_key = if (index == 0 and std.mem.eql(u8, arg_key.string, "$")) args.keys()[0] else arg_key;
                    const correct_index = args.getIndex(actual_arg_key).?;

                    if (correct_index != index) {
                        ordered = false;

                        // TODO: both OP_SWAP args could fit in a 32 bit instruction
                        try codegen.emitCodeArg(node.location, .OP_SWAP, @intCast(u24, arg_count - index - 1));
                        // to where it should be
                        try codegen.emit(node.location, @intCast(u32, arg_count - correct_index - 1));

                        // Switch it in the reference
                        var temp = arguments_order_ref.items[index];
                        arguments_order_ref.items[index] = arguments_order_ref.items[correct_index];
                        arguments_order_ref.items[correct_index] = temp;

                        // Stop (so we can take the swap into account) and try again
                        break;
                    }
                }

                if (ordered) break;
            }
        }

        // Catch clause
        const error_types = callee_type.?.resolved_type.?.Function.error_types;
        if (self.catch_default) |catch_default| {
            if (error_types == null or error_types.?.len == 0) {
                try codegen.reportErrorAt(node.location, "Function doesn't raise any error");
            } else if (error_types != null) {
                if (catch_default.type_def == null or catch_default.type_def.?.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(catch_default.type_def.?.resolved_type.?.Placeholder);
                } else {
                    // Expression
                    if (!node.type_def.?.eql(catch_default.type_def.?)) {
                        try codegen.reportTypeCheckAt(
                            node.type_def.?,
                            catch_default.type_def.?.resolved_type.?.Function.return_type,
                            "Bad inline catch value type",
                            catch_default.location,
                        );
                    }
                }

                _ = try catch_default.toByteCode(catch_default, codegen, breaks);
            }
        } else if (error_types) |errors| {
            if (codegen.current.?.enclosing != null and codegen.current.?.function.?.type_def.resolved_type.?.Function.function_type != .Test) {
                var not_handled = std.ArrayList(*ObjTypeDef).init(codegen.gc.allocator);
                defer not_handled.deinit();
                for (errors) |error_type| {
                    var handled = false;

                    if (codegen.current.?.function.?.type_def.resolved_type.?.Function.error_types) |handled_types| {
                        for (handled_types) |handled_type| {
                            if (error_type.eql(handled_type)) {
                                handled = true;
                                break;
                            }
                        }
                    }

                    if (!handled) {
                        if (codegen.current.?.try_should_handle != null) {
                            try codegen.current.?.try_should_handle.?.put(error_type, {});
                        } else {
                            try not_handled.append(error_type);
                        }
                    }
                }

                for (not_handled.items) |error_type| {
                    const error_str = try error_type.toStringAlloc(codegen.gc.allocator);
                    defer codegen.gc.allocator.free(error_str);

                    try codegen.reportErrorFmt(node.location, "Error `{s}` is not handled", .{error_str});
                }
            }
        }

        // This is an async call, create a fiber
        if (self.async_call) {
            if (!invoked and self.super == null) {
                // zig fmt: off
                const call_arg_count = if (!invoked and self.super == null) @intCast(u8, arguments_order_ref.items.len)
                    else
                        if (self.super == null and (invoked_on != null and invoked_on.? != .ObjectInstance)) @intCast(u8, self.arguments.count()) + 1 
                        else @intCast(u8, self.arguments.count());
                // zig fmt: on

                try codegen.emitCodeArgs(
                    self.node.location,
                    .OP_ROUTINE,
                    call_arg_count,
                    if (self.catch_default != null) 1 else 0,
                );

                try node.patchOptJumps(codegen);
                try node.endScope(codegen);

                return null;
            } else {
                if (invoked) {
                    try codegen.emitCodeArg(
                        self.node.location,
                        .OP_INVOKE_ROUTINE,
                        try codegen.identifierConstant(DotNode.cast(self.callee).?.identifier.lexeme),
                    );
                } else if (self.super) |super| {
                    // Push super as a new local
                    _ = try super.node.toByteCode(&super.node, codegen, breaks);

                    try codegen.emitCodeArg(
                        self.node.location,
                        .OP_SUPER_INVOKE_ROUTINE,
                        try codegen.identifierConstant(SuperNode.cast(self.callee).?.identifier.lexeme),
                    );
                }

                try codegen.emitTwo(
                    self.node.location,
                    if (self.super == null and (invoked_on != null and invoked_on.? != .ObjectInstance)) @intCast(u8, self.arguments.count()) + 1 else @intCast(u8, self.arguments.count()),
                    if (self.catch_default != null) 1 else 0,
                );

                try node.patchOptJumps(codegen);
                try node.endScope(codegen);

                return null;
            }
        }

        // Normal call/invoke
        if (invoked) {
            // TODO: can it be invoked without callee being a DotNode?
            try codegen.emitCodeArg(
                self.node.location,
                .OP_INVOKE,
                try codegen.identifierConstant(DotNode.cast(self.callee).?.identifier.lexeme),
            );
        } else if (self.super) |super| {
            // Push super as a new local
            _ = try super.node.toByteCode(&super.node, codegen, breaks);

            try codegen.emitCodeArg(
                self.node.location,
                .OP_SUPER_INVOKE,
                try codegen.identifierConstant(SuperNode.cast(self.callee).?.identifier.lexeme),
            );
        }

        if (!invoked and self.super == null) {
            try codegen.emitCodeArgs(
                self.node.location,
                .OP_CALL,
                @intCast(u8, arguments_order_ref.items.len),
                if (self.catch_default != null) 1 else 0,
            );
        } else {
            try codegen.emitTwo(
                self.node.location,
                if (self.super == null and (invoked_on != null and invoked_on.? != .ObjectInstance)) @intCast(u8, self.arguments.count()) + 1 else @intCast(u8, self.arguments.count()),
                if (self.catch_default != null) 1 else 0,
            );
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Call\"");

        var invoked = false;
        var invoked_on = false;
        if (self.callee.node_type == .Dot) {
            const dot = DotNode.cast(self.callee).?;
            const field_accessed = dot.callee.type_def;

            invoked = field_accessed.?.def_type != .Object;
            invoked_on = true;
        }

        if (!invoked and self.super == null and !invoked_on) {
            try out.writeAll(", \"callee\": ");
            try self.callee.toJson(self.callee, out);
        }

        try out.writeAll(", \"arguments\": [");

        for (self.arguments.keys()) |key, i| {
            const argument = self.arguments.get(key).?;

            try out.print("{{\"name\": \"{s}\", \"value\": ", .{key.string});

            try argument.toJson(argument, out);

            try out.writeAll("}");

            if (i < self.arguments.keys().len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        if (self.catch_default) |default| {
            try out.writeAll("\"catch_default\": ");

            try default.toJson(default, out);

            try out.writeAll(",");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator, callee: *ParseNode) Self {
        return Self{
            .callee = callee,
            .arguments = std.ArrayList(ParsedArg).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.callee.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Call) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const FunDeclarationNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .FunDeclaration,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    function: *FunctionNode,
    slot: usize,
    slot_type: SlotType,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.function.node.toByteCode(&self.function.node, codegen, breaks);

        if (self.slot_type == .Global) {
            try codegen.emitCodeArg(self.node.location, .OP_DEFINE_GLOBAL, @intCast(u24, self.slot));
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"FunDeclaration\",\"slot_type\": \"{}\",\"function\": ", .{self.slot_type});

        try self.function.node.toJson(&self.function.node, out);

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .FunDeclaration) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const VarDeclarationNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .VarDeclaration,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    name: Token,
    value: ?*ParseNode = null,
    type_def: ?*ObjTypeDef = null,
    type_name: ?Token = null,
    constant: bool,
    slot: usize,
    slot_type: SlotType,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.value) |value| {
            if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
            } else if (self.type_def == null or self.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(self.type_def.?.resolved_type.?.Placeholder);
            } else if (!(try self.type_def.?.toInstance(codegen.gc.allocator, &codegen.gc.type_registry)).eql(value.type_def.?) and !(try (try self.type_def.?.toInstance(codegen.gc.allocator, &codegen.gc.type_registry)).cloneNonOptional(&codegen.gc.type_registry)).eql(value.type_def.?)) {
                try codegen.reportTypeCheckAt(
                    try self.type_def.?.toInstance(codegen.gc.allocator, &codegen.gc.type_registry),
                    value.type_def.?,
                    "Wrong variable type",
                    value.location,
                );
            }

            _ = try value.toByteCode(value, codegen, breaks);
        } else {
            try codegen.emitOpCode(self.node.location, .OP_NULL);
        }

        if (self.slot_type == .Global) {
            try codegen.emitCodeArg(self.node.location, .OP_DEFINE_GLOBAL, @intCast(u24, self.slot));
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print(
            "{{\"node\": \"VarDeclaration\", \"name\": \"{s}\", \"constant\": {}, \"var_type\": \"",
            .{
                self.name.lexeme,
                self.constant,
            },
        );

        if (self.type_def) |type_def| {
            try type_def.toString(out);
        }

        try out.print(
            " @{}\", ",
            .{
                if (self.type_def) |type_def| @ptrToInt(type_def) else 0,
            },
        );

        if (self.value) |value| {
            try out.writeAll("\"value\": ");

            try value.toJson(value, out);

            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .VarDeclaration) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const EnumNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Enum,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    slot: usize,
    cases: std.ArrayList(*ParseNode),

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const enum_type = node.type_def.?.resolved_type.?.Enum.enum_type;

        if (enum_type.def_type == .Placeholder) {
            try codegen.reportPlaceholder(enum_type.resolved_type.?.Placeholder);

            return null;
        }

        switch (enum_type.def_type) {
            .String, .Number => {},
            else => {
                try codegen.reportErrorAt(node.location, "Type not allowed as enum value");
                return null;
            },
        }

        try codegen.emitCodeArg(self.node.location, .OP_ENUM, try codegen.makeConstant(node.type_def.?.toValue()));
        try codegen.emitCodeArg(self.node.location, .OP_DEFINE_GLOBAL, @intCast(u24, self.slot));

        try codegen.emitCodeArg(self.node.location, .OP_GET_GLOBAL, @intCast(u24, self.slot));

        for (self.cases.items) |case| {
            if (case.type_def == null or case.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(case.type_def.?.resolved_type.?.Placeholder);
            } else if (!((try enum_type.toInstance(codegen.gc.allocator, &codegen.gc.type_registry))).eql(case.type_def.?)) {
                try codegen.reportTypeCheckAt(
                    (try enum_type.toInstance(codegen.gc.allocator, &codegen.gc.type_registry)),
                    case.type_def.?,
                    "Bad enum case type",
                    case.location,
                );
            }

            _ = try case.toByteCode(case, codegen, breaks);

            try codegen.emitOpCode(self.node.location, .OP_ENUM_CASE);
        }

        try codegen.emitOpCode(self.node.location, .OP_POP);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Enum\", \"cases\": [");

        for (self.cases.items) |case, i| {
            try case.toJson(case, out);
            if (i < self.cases.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .cases = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cases.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Enum) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ThrowNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Throw,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    error_value: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        assert(self.error_value.type_def != null);
        if (self.error_value.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.error_value.type_def.?.resolved_type.?.Placeholder);
        } else {
            const current_error_types = codegen.current.?.function.?.type_def.resolved_type.?.Function.error_types;
            if (current_error_types != null) {
                var found_match = false;
                for (current_error_types.?) |error_type| {
                    if (error_type.eql(self.error_value.type_def.?)) {
                        found_match = true;
                        break;
                    }
                }

                if (!found_match) {
                    if (codegen.current.?.try_should_handle != null) {
                        // In a try catch remember to check that we handle that error when finishing parsing the try-catch
                        try codegen.current.?.try_should_handle.?.put(self.error_value.type_def.?, {});
                    } else {
                        // Not in a try-catch and function signature does not expect this error type
                        const error_str = try self.error_value.type_def.?.toStringAlloc(codegen.gc.allocator);
                        defer codegen.gc.allocator.free(error_str);

                        try codegen.reportErrorFmt(node.location, "Error type `{s}` not expected", .{error_str});
                    }
                }
            }
        }

        _ = try self.error_value.toByteCode(self.error_value, codegen, breaks);

        try codegen.emitOpCode(self.node.location, .OP_THROW);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Throw\", \"error_value\": ");

        try self.error_value.toJson(self.error_value, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Throw) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BreakNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Break,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        assert(breaks != null);

        // Close scope(s), then jump
        try node.endScope(codegen);
        try breaks.?.append(try codegen.emitJump(node.location, .OP_JUMP));

        // TODO: not sur if this makes sense here
        try node.patchOptJumps(codegen);

        return null;
    }

    fn stringify(_: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        try out.writeAll("{\"node\": \"Break\" }");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Break) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ContinueNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Continue,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        assert(breaks != null);

        // Close scope(s), then jump
        try node.endScope(codegen);
        try breaks.?.append(try codegen.emitJump(node.location, .OP_LOOP));

        // TODO: not sur if this makes sense here
        try node.patchOptJumps(codegen);

        return null;
    }

    fn stringify(_: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        try out.writeAll("{\"node\": \"Continue\" }");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Continue) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const IfNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .If,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    condition: *ParseNode,
    unwrapped_identifier: bool,
    body: *ParseNode,
    else_branch: ?*ParseNode = null,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.condition.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.unwrapped_identifier) {
            if (!self.condition.type_def.?.optional) {
                try codegen.reportErrorAt(self.condition.location, "Expected optional");
            }
        } else {
            if (self.condition.type_def.?.def_type != .Bool) {
                try codegen.reportErrorAt(self.condition.location, "`if` condition must be bool");
            }
        }

        // If condition is a constant expression, no need to generate branches
        if (self.condition.isConstant(self.condition) and !self.unwrapped_identifier) {
            const condition = try self.condition.toValue(self.condition, codegen.gc);

            if (condition.Boolean) {
                _ = try self.body.toByteCode(self.body, codegen, breaks);
            } else if (self.else_branch) |else_branch| {
                _ = try else_branch.toByteCode(else_branch, codegen, breaks);
            }

            try node.patchOptJumps(codegen);
            try node.endScope(codegen);

            return null;
        }

        _ = try self.condition.toByteCode(self.condition, codegen, breaks);
        if (self.unwrapped_identifier) {
            try codegen.emitOpCode(self.condition.location, .OP_COPY);
            try codegen.emitOpCode(self.condition.location, .OP_NULL);
            try codegen.emitOpCode(self.condition.location, .OP_EQUAL);
            try codegen.emitOpCode(self.condition.location, .OP_NOT);
        }

        const then_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(self.node.location, .OP_POP);

        _ = try self.body.toByteCode(self.body, codegen, breaks);

        const else_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP);

        try codegen.patchJump(then_jump);
        if (self.unwrapped_identifier) {
            // Since we did not enter the if block, we did not pop the unwrapped local
            try codegen.emitOpCode(self.node.location, .OP_POP);
        }
        try codegen.emitOpCode(self.node.location, .OP_POP);

        if (self.else_branch) |else_branch| {
            _ = try else_branch.toByteCode(else_branch, codegen, breaks);
        }

        try codegen.patchJump(else_jump);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"If\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"body\": ");

        try self.body.toJson(self.body, out);

        if (self.else_branch) |else_branch| {
            try out.writeAll(", \"else\": ");
            try else_branch.toJson(else_branch, out);
        }

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .If) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ReturnNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Return,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    value: ?*ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        codegen.current.?.return_emitted = true;

        if (self.value) |value| {
            if (value.type_def == null) {
                try codegen.reportErrorAt(value.location, "Unknown type.");
            } else if (value.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
            } else if (!codegen.current.?.function.?.type_def.resolved_type.?.Function.return_type.eql(value.type_def.?)) {
                try codegen.reportTypeCheckAt(
                    codegen.current.?.function.?.type_def.resolved_type.?.Function.return_type,
                    value.type_def.?,
                    "Return value",
                    value.location,
                );
            }

            _ = try value.toByteCode(value, codegen, breaks);
        } else {
            try codegen.emitOpCode(self.node.location, .OP_VOID);
        }

        try codegen.emitOpCode(self.node.location, .OP_RETURN);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Return\", ");

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Return) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .For,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    init_declarations: std.ArrayList(*VarDeclarationNode),
    condition: *ParseNode,
    post_loop: std.ArrayList(*ParseNode),
    body: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        if (self.condition.isConstant(self.condition) and !(try self.condition.toValue(self.condition, codegen.gc)).Boolean) {
            try node.patchOptJumps(codegen);

            return null;
        }

        for (self.init_declarations.items) |var_declaration| {
            _ = try var_declaration.node.toByteCode(&var_declaration.node, codegen, _breaks);
        }

        const loop_start: usize = codegen.currentCode();

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.condition.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`for` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, _breaks);

        const exit_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition

        // Jump over expressions which will be executed at end of loop
        // TODO: since we don't generate as we parse, we can get rid of this jump and just generate the post_loop later
        var body_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP);

        const expr_loop: usize = codegen.currentCode();
        for (self.post_loop.items) |expr| {
            if (expr.type_def == null or expr.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(expr.type_def.?.resolved_type.?.Placeholder);
            }

            _ = try expr.toByteCode(expr, codegen, _breaks);
            try codegen.emitOpCode(expr.location, .OP_POP);
        }

        try codegen.emitLoop(self.node.location, loop_start);

        try codegen.patchJump(body_jump);

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.gc.allocator);
        defer breaks.deinit();

        _ = try self.body.toByteCode(self.body, codegen, &breaks);

        try codegen.emitLoop(self.node.location, expr_loop);

        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"For\", \"init_declarations\": [");

        for (self.init_declarations.items) |var_declaration, i| {
            try var_declaration.node.toJson(&var_declaration.node, out);

            if (i < self.init_declarations.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"post_loop\": [");

        for (self.post_loop.items) |expression| {
            try expression.toJson(expression, out);
            try out.writeAll(", ");
        }

        try out.writeAll("], \"body\": ");

        try self.body.toJson(self.body, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_declarations = std.ArrayList(*VarDeclarationNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_declarations.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .For) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForEachNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ForEach,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    key: ?*VarDeclarationNode = null,
    value: *VarDeclarationNode,
    iterable: *ParseNode,
    block: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        // Type checking
        if (self.iterable.type_def == null or self.iterable.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.iterable.location, "Unknown type.");
            try codegen.reportPlaceholder(self.iterable.type_def.?.resolved_type.?.Placeholder);
        } else {
            if (self.key) |key| {
                if (key.type_def == null or key.type_def.?.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(key.type_def.?.resolved_type.?.Placeholder);
                }

                switch (self.iterable.type_def.?.def_type) {
                    .String, .List => {
                        if (key.type_def.?.def_type != .Number) {
                            try codegen.reportErrorAt(key.node.location, "Expected `num`.");
                        }
                    },
                    .Map => {
                        if (!self.iterable.type_def.?.resolved_type.?.Map.key_type.eql(key.type_def.?)) {
                            try codegen.reportTypeCheckAt(self.iterable.type_def.?.resolved_type.?.Map.key_type, key.type_def.?, "Bad key type", key.node.location);
                        }
                    },
                    .Enum => try codegen.reportErrorAt(key.node.location, "No key available when iterating over enum."),
                    else => try codegen.reportErrorAt(self.iterable.location, "Not iterable."),
                }
            }

            if (self.value.type_def == null or self.value.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(self.value.type_def.?.resolved_type.?.Placeholder);
            }

            switch (self.iterable.type_def.?.def_type) {
                .Map => {
                    if (!self.iterable.type_def.?.resolved_type.?.Map.value_type.eql(self.value.type_def.?)) {
                        try codegen.reportTypeCheckAt(
                            self.iterable.type_def.?.resolved_type.?.Map.value_type,
                            self.value.type_def.?,
                            "Bad value type",
                            self.value.node.location,
                        );
                    }
                },
                .List => {
                    if (!self.iterable.type_def.?.resolved_type.?.List.item_type.eql(self.value.type_def.?)) {
                        try codegen.reportTypeCheckAt(
                            self.iterable.type_def.?.resolved_type.?.List.item_type,
                            self.value.type_def.?,
                            "Bad value type",
                            self.value.node.location,
                        );
                    }
                },
                .String => {
                    if (self.value.type_def.?.def_type != .String) {
                        try codegen.reportErrorAt(self.value.node.location, "Expected `str`.");
                    }
                },
                .Enum => {
                    const iterable_type = try self.iterable.type_def.?.toInstance(codegen.gc.allocator, &codegen.gc.type_registry);
                    if (!iterable_type.eql(self.value.type_def.?)) {
                        try codegen.reportTypeCheckAt(
                            iterable_type,
                            self.value.type_def.?,
                            "Bad value type",
                            self.value.node.location,
                        );
                    }
                },
                .Fiber => {
                    const iterable_type = try self.iterable.type_def.?.resolved_type.?.Fiber.yield_type.toInstance(
                        codegen.gc.allocator,
                        &codegen.gc.type_registry,
                    );
                    if (!iterable_type.eql(self.value.type_def.?)) {
                        try codegen.reportTypeCheckAt(
                            iterable_type,
                            self.value.type_def.?,
                            "Bad value type",
                            self.value.node.location,
                        );
                    }
                },
                else => try codegen.reportErrorAt(self.iterable.location, "Not iterable."),
            }
        }

        // If iterable constant and empty, skip the node
        if (self.iterable.isConstant(self.iterable)) {
            const iterable = (try self.iterable.toValue(self.iterable, codegen.gc)).Obj;

            if (switch (iterable.obj_type) {
                .List => ObjList.cast(iterable).?.items.items.len == 0,
                .Map => ObjMap.cast(iterable).?.map.count() == 0,
                .String => ObjString.cast(iterable).?.string.len == 0,
                .Enum => ObjEnum.cast(iterable).?.cases.items.len == 0,
                else => unreachable,
            }) {
                try node.patchOptJumps(codegen);
                return null;
            }
        }

        if (self.key) |key| {
            _ = try key.node.toByteCode(&key.node, codegen, _breaks);
        }
        _ = try self.value.node.toByteCode(&self.value.node, codegen, _breaks);
        _ = try self.iterable.toByteCode(self.iterable, codegen, _breaks);

        const loop_start: usize = codegen.currentCode();

        // Calls `next` and update key and value locals
        try codegen.emitOpCode(self.node.location, .OP_FOREACH);

        // If next key is null, exit loop
        try codegen.emitCodeArg(self.node.location, .OP_GET_LOCAL, @intCast(u24, (self.key orelse self.value).slot));
        try codegen.emitOpCode(self.node.location, .OP_NULL);
        try codegen.emitOpCode(self.node.location, .OP_EQUAL);
        try codegen.emitOpCode(self.node.location, .OP_NOT);
        const exit_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition result

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.gc.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        try codegen.emitLoop(self.node.location, loop_start);

        // Patch condition jump
        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition result

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }

        try node.patchOptJumps(codegen);
        // Should have key, [value,] iterable to pop
        assert(node.ends_scope != null and node.ends_scope.?.items.len >= 2);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ForEach\", ");

        if (self.key) |key| {
            try out.writeAll("\"key\": ");
            try key.node.toJson(&key.node, out);
        }

        try out.writeAll(", \"value\": ");

        try self.value.node.toJson(&self.value.node, out);

        try out.writeAll(", \"iterable\": ");

        try self.iterable.toJson(self.iterable, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ForEach) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const WhileNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .While,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    condition: *ParseNode,
    block: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        // If condition constant and false, skip the node
        if (self.condition.isConstant(self.condition) and !(try self.condition.toValue(self.condition, codegen.gc)).Boolean) {
            try node.patchOptJumps(codegen);
            try node.endScope(codegen);

            return null;
        }

        const loop_start: usize = codegen.currentCode();

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(self.condition.type_def.?.resolved_type.?.Placeholder);
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`while` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, _breaks);

        const exit_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(self.node.location, .OP_POP);

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.gc.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        try codegen.emitLoop(self.node.location, loop_start);
        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition (is not necessary if broke out of the loop)

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"While\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .While) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const DoUntilNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .DoUntil,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    condition: *ParseNode,
    block: *ParseNode,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        const loop_start: usize = codegen.currentCode();

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.gc.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.condition.location, "Unknown type.");
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`do` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, &breaks);

        try codegen.emitOpCode(self.node.location, .OP_NOT);
        const exit_jump: usize = try codegen.emitJump(self.node.location, .OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(self.node.location, .OP_POP);

        try codegen.emitLoop(self.node.location, loop_start);
        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(self.node.location, .OP_POP); // Pop condition

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"DoUntil\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .DoUntil) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BlockNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Block,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    statements: std.ArrayList(*ParseNode),

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        for (self.statements.items) |statement| {
            _ = try statement.toByteCode(statement, codegen, breaks);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Block\", \"statements\": [");

        for (self.statements.items) |statement, i| {
            try statement.toJson(statement, out);

            if (i < self.statements.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .statements = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.statements.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Block) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const SuperNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Super,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    identifier: Token,
    member_type_def: ?*ObjTypeDef = null,
    // if call, CallNode will fetch super
    super: ?*NamedVariableNode = null,
    this: *NamedVariableNode,
    call: ?*CallNode = null,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.this.node.toByteCode(&self.this.node, codegen, breaks);

        if (self.call) |call| {
            _ = try call.node.toByteCode(&call.node, codegen, breaks);
        } else {
            assert(self.super != null);

            _ = try self.super.?.node.toByteCode(&self.super.?.node, codegen, breaks);

            try codegen.emitCodeArg(self.node.location, .OP_GET_SUPER, try codegen.identifierConstant(self.identifier.lexeme));
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Super\", \"member_name\": \"{s}\", \"this\": ", .{self.identifier.lexeme});

        try self.this.node.toJson(&self.this.node, out);
        try out.writeAll(",");

        if (self.super) |super| {
            try out.writeAll("\"super\": ");
            try super.node.toJson(&super.node, out);
            try out.writeAll(",");
        }

        if (self.call) |call| {
            try out.writeAll("\"call\": ");
            try call.node.toJson(&call.node, out);
            try out.writeAll(",");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Super) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const DotNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Dot,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    callee: *ParseNode,
    identifier: Token,
    member_type_def: ?*ObjTypeDef = null,
    value: ?*ParseNode = null,
    call: ?*CallNode = null,
    enum_index: ?usize = null,

    fn constant(_: *ParseNode) bool {
        // TODO: should be true, but we have to evaluate a constant call
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.callee.toByteCode(self.callee, codegen, breaks);

        const callee_type = self.callee.type_def.?;

        if (callee_type.def_type == .Placeholder) {
            try codegen.reportPlaceholder(callee_type.resolved_type.?.Placeholder);
        }

        // zig fmt: off
        if (callee_type.def_type != .ObjectInstance
            and callee_type.def_type != .Object
            and callee_type.def_type != .Enum
            and callee_type.def_type != .EnumInstance
            and callee_type.def_type != .List
            and callee_type.def_type != .Map
            and callee_type.def_type != .String
            and callee_type.def_type != .Pattern
            and callee_type.def_type != .Fiber) {
            try codegen.reportErrorAt(node.location, "Doesn't have field access");
        }
        // zig fmt: on

        if (callee_type.optional) {
            try codegen.reportErrorAt(node.location, "Optional doesn't have field access");
        }

        switch (callee_type.def_type) {
            .Fiber, .Pattern, .String => {
                if (self.call) |call_node| { // Call
                    try codegen.emitOpCode(self.node.location, .OP_COPY);
                    _ = try call_node.node.toByteCode(&call_node.node, codegen, breaks);
                } else { // Expression
                    try codegen.emitCodeArg(self.node.location, .OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            .ObjectInstance, .Object => {
                if (self.value) |value| {
                    if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                        try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
                    }

                    _ = try value.toByteCode(value, codegen, breaks);

                    try codegen.emitCodeArg(self.node.location, .OP_SET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                } else if (self.call) |call| {
                    // Static call
                    if (callee_type.def_type == .Object) {
                        try codegen.emitCodeArg(node.location, .OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                    }

                    _ = try call.node.toByteCode(&call.node, codegen, breaks);
                } else {
                    try codegen.emitCodeArg(self.node.location, .OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            .Enum => {
                try codegen.emitCodeArg(self.node.location, .OP_GET_ENUM_CASE, @intCast(u24, self.enum_index.?));
            },
            .EnumInstance => {
                assert(std.mem.eql(u8, self.identifier.lexeme, "value"));

                try codegen.emitOpCode(self.node.location, .OP_GET_ENUM_CASE_VALUE);
            },
            .List, .Map => {
                if (self.call) |call| {
                    try codegen.emitOpCode(self.node.location, .OP_COPY);

                    _ = try call.node.toByteCode(&call.node, codegen, breaks);
                } else {
                    try codegen.emitCodeArg(self.node.location, .OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            else => unreachable,
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Dot\", \"callee\": ");

        try self.callee.toJson(self.callee, out);

        try out.print(", \"identifier\": \"{s}\", ", .{self.identifier.lexeme});

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
            try out.writeAll(", ");
        }

        if (self.call) |call| {
            try out.writeAll("\"call\": ");
            try call.toNode().toJson(call.toNode(), out);
            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Dot) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ObjectInitNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ObjectInit,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    object: ?*ParseNode, // Should mostly be a NamedVariableNode
    properties: std.StringArrayHashMap(*ParseNode),

    fn getSuperField(self: *Self, object: *ObjTypeDef, name: []const u8) ?*ObjTypeDef {
        const obj_def: ObjObject.ObjectDef = object.resolved_type.?.Object;
        if (obj_def.fields.get(name)) |obj_field| {
            return obj_field;
        } else if (obj_def.super) |obj_super| {
            return self.getSuperField(obj_super, name);
        }

        return null;
    }

    fn checkOmittedProperty(self: *Self, codegen: *CodeGen, obj_def: ObjObject.ObjectDef, init_properties: std.StringHashMap(void)) anyerror!void {
        var it = obj_def.fields.iterator();
        while (it.next()) |kv| {
            // If ommitted in initialization and doesn't have default value
            if (init_properties.get(kv.key_ptr.*) == null and obj_def.fields_defaults.get(kv.key_ptr.*) == null) {
                try codegen.reportErrorFmt(self.node.location, "Property `{s}` was not initialized and has no default value", .{kv.key_ptr.*});
            }
        }

        if (obj_def.super) |super_def| {
            try self.checkOmittedProperty(codegen, super_def.resolved_type.?.Object, init_properties);
        }
    }

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.object) |object| {
            _ = try object.toByteCode(object, codegen, breaks);
        } else {
            // Anonymous object, we push its type
            try codegen.emitCodeArg(
                node.location,
                .OP_CONSTANT,
                try codegen.makeConstant(node.type_def.?.toValue()),
            );
        }

        try codegen.emitOpCode(self.node.location, .OP_INSTANCE);

        if (node.type_def == null or node.type_def.?.def_type == .Placeholder) {
            try codegen.reportPlaceholder(node.type_def.?.resolved_type.?.Placeholder);
        } else if (node.type_def.?.def_type != .ObjectInstance) {
            try codegen.reportErrorAt(node.location, "Expected an object or a class.");
        }

        const object_type = node.type_def.?.resolved_type.?.ObjectInstance;
        const obj_def = object_type.resolved_type.?.Object;

        // To keep track of what's been initialized or not by this statement
        var init_properties = std.StringHashMap(void).init(codegen.gc.allocator);
        defer init_properties.deinit();

        for (self.properties.keys()) |property_name| {
            const property_name_constant: u24 = try codegen.identifierConstant(property_name);
            const value = self.properties.get(property_name).?;

            if (obj_def.fields.get(property_name) orelse self.getSuperField(object_type, property_name)) |prop| {
                try codegen.emitCodeArg(self.node.location, .OP_COPY, 0); // Will be popped by OP_SET_PROPERTY

                if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(value.type_def.?.resolved_type.?.Placeholder);
                } else if (!prop.eql(value.type_def.?)) {
                    if (Config.debug_placeholders) {
                        std.debug.print(
                            "prop {}({}), value {}({})\n",
                            .{
                                @ptrToInt(prop.resolved_type.?.ObjectInstance),
                                prop.optional,
                                @ptrToInt(value.type_def.?.resolved_type.?.ObjectInstance),
                                value.type_def.?.optional,
                            },
                        );
                    }
                    try codegen.reportTypeCheckAt(prop, value.type_def.?, "Wrong property type", value.location);
                }

                _ = try value.toByteCode(value, codegen, breaks);

                try init_properties.put(property_name, {});

                try codegen.emitCodeArg(self.node.location, .OP_SET_PROPERTY, property_name_constant);
                try codegen.emitOpCode(self.node.location, .OP_POP); // Pop property value
            } else {
                try codegen.reportErrorFmt(node.location, "Property `{s}` does not exists", .{property_name});
            }
        }

        // Did we initialized all properties without a default value?
        try self.checkOmittedProperty(codegen, obj_def, init_properties);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ObjectInit\", \"properties\": {");

        var it = self.properties.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) {
                try out.writeAll(",");
            }

            first = false;

            try out.print("\"{s}\": ", .{entry.key_ptr.*});

            try entry.value_ptr.*.toJson(entry.value_ptr.*, out);
        }

        try out.writeAll("}, ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator, object: ?*ParseNode) Self {
        return Self{
            .object = object,
            .properties = std.StringArrayHashMap(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ObjectInit) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ObjectDeclarationNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ObjectDeclaration,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    parent_slot: ?usize = null,
    slot: usize,
    methods: std.StringHashMap(*ParseNode),
    properties: std.StringHashMap(?*ParseNode),
    properties_type: std.StringHashMap(*ObjTypeDef),
    docblocks: std.StringHashMap(?Token),

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const object_type = node.type_def.?;
        const name_constant = try codegen.makeConstant(object_type.resolved_type.?.Object.name.toValue());
        const object_type_constant = try codegen.makeConstant(object_type.toValue());

        // Put  object on the stack and define global with it
        try codegen.emitCodeArg(self.node.location, .OP_OBJECT, name_constant);
        try codegen.emit(self.node.location, @intCast(u32, object_type_constant));
        try codegen.emitCodeArg(self.node.location, .OP_DEFINE_GLOBAL, @intCast(u24, self.slot));

        // Does it inherits from another object/class
        if (self.parent_slot) |parent_slot| {
            // Put parent on the stack as the `super` local
            try codegen.emitCodeArg(self.node.location, .OP_GET_GLOBAL, @intCast(u24, parent_slot));

            // Actually do the inheritance
            try codegen.emitCodeArg(self.node.location, .OP_GET_GLOBAL, @intCast(u24, self.slot));
            try codegen.emitCodeArg(self.node.location, .OP_INHERIT, @intCast(u24, parent_slot));
        }

        // Put the object on the stack to set its fields
        try codegen.emitCodeArg(self.node.location, .OP_GET_GLOBAL, @intCast(u24, self.slot));

        // Methods
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            const member_name = kv.key_ptr.*;
            const member = kv.value_ptr.*;
            const member_name_constant: u24 = try codegen.identifierConstant(member_name);

            if (member.type_def == null or member.type_def.?.def_type == .Placeholder) {
                try codegen.reportPlaceholder(member.type_def.?.resolved_type.?.Placeholder);
            }

            const is_static = object_type.resolved_type.?.Object.static_fields.get(member_name) != null;

            _ = try member.toByteCode(member, codegen, breaks);
            try codegen.emitCodeArg(self.node.location, if (is_static) .OP_PROPERTY else .OP_METHOD, member_name_constant);
        }

        // Properties
        var it2 = self.properties.iterator();
        while (it2.next()) |kv| {
            const member_name = kv.key_ptr.*;
            const member = kv.value_ptr.*;
            const member_name_constant: u24 = try codegen.identifierConstant(member_name);
            const is_static = object_type.resolved_type.?.Object.static_fields.get(member_name) != null;
            const property_type = object_type.resolved_type.?.Object.fields.get(member_name) orelse object_type.resolved_type.?.Object.static_fields.get(member_name);

            assert(property_type != null);

            // Create property default value
            if (member) |default| {
                if (default.type_def == null or default.type_def.?.def_type == .Placeholder) {
                    try codegen.reportPlaceholder(default.type_def.?.resolved_type.?.Placeholder);
                } else if (!property_type.?.eql(default.type_def.?)) {
                    try codegen.reportTypeCheckAt(property_type.?, default.type_def.?, "Wrong property default value type", default.location);
                }

                if (is_static) {
                    try codegen.emitOpCode(self.node.location, .OP_COPY);
                }

                _ = try default.toByteCode(default, codegen, breaks);

                // Create property default value
                if (is_static) {
                    try codegen.emitCodeArg(self.node.location, .OP_SET_PROPERTY, member_name_constant);
                    try codegen.emitOpCode(self.node.location, .OP_POP);
                } else {
                    try codegen.emitCodeArg(self.node.location, .OP_PROPERTY, member_name_constant);
                }
            }
        }

        // Pop object
        try codegen.emitOpCode(self.node.location, .OP_POP);

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ObjectDeclaration\", \"methods\": {");

        var it = self.methods.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
            const member = kv.value_ptr.*;

            try out.print("\"{s}\": ", .{kv.key_ptr.*});

            try member.toJson(member, out);

            if (i < self.methods.count() - 1) {
                try out.writeAll(",");
            }

            i += 1;
        }

        try out.writeAll("}, \"members\": {");

        var it2 = self.properties_type.iterator();
        i = 0;
        while (it2.next()) |kv| {
            try out.print(
                "\"{s}\": {{\"type_def\": \"",
                .{
                    kv.key_ptr.*,
                },
            );

            try kv.value_ptr.*.toString(out);

            try out.print(
                "\", \"docblock\": \"{s}\"}}",
                .{
                    if (self.docblocks.get(kv.key_ptr.*).?) |docblock| docblock.literal_string orelse "" else "",
                },
            );

            if (i < self.properties_type.count() - 1) {
                try out.writeAll(",");
            }

            i += 1;
        }

        try out.writeAll("}, ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .properties = std.StringHashMap(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ObjectDeclaration) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ExportNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Export,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    identifier: Token,
    alias: ?Token = null,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, _: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Export\", \"identifier\": \"{s}\", ", .{self.identifier.lexeme});

        if (self.alias) |alias| {
            try out.print("\"alias\": \"{s}\", ", .{alias.lexeme});
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Export) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ImportNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Import,
        .toJson = stringify,
        .toByteCode = generate,
        .toValue = val,
        .isConstant = constant,
    },

    imported_symbols: ?std.StringHashMap(void) = null,
    prefix: ?Token = null,
    path: Token,
    import: ?Parser.ScriptImport,

    fn constant(_: *ParseNode) bool {
        return false;
    }

    fn val(_: *ParseNode, _: *GarbageCollector) anyerror!Value {
        return GenError.NotConstant;
    }

    fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (node.synchronize(codegen)) {
            return null;
        }

        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.import) |import| {
            try codegen.emitConstant(
                node.location,
                import.absolute_path.toValue(),
            );
            _ = try import.function.toByteCode(import.function, codegen, breaks);
            // FIXME: avoid generating the same import function more than once!
            try codegen.emitOpCode(self.node.location, .OP_IMPORT);
        }

        try node.patchOptJumps(codegen);
        try node.endScope(codegen);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) ToJsonError!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Import\", \"path\": \"{s}\"", .{self.path.literal_string.?});

        if (self.prefix) |prefix| {
            try out.print(",\"prefix\": \"{s}\"", .{prefix.lexeme});
        }

        try out.writeAll(",\"imported_symbols\": [");
        if (self.imported_symbols) |imported_symbols| {
            var key_it = imported_symbols.keyIterator();
            var total = imported_symbols.count();
            var count: usize = 0;
            while (key_it.next()) |symbol| {
                try out.print("\"{s}\"", .{symbol});

                if (count < total - 1) {
                    try out.writeAll(",");
                }

                count += 1;
            }
        }
        try out.writeAll("]");

        if (self.import) |import| {
            try out.writeAll(",\"import\": ");
            try import.function.toJson(import.function, out);
        }

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Import) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};
