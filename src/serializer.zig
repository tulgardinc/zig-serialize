//! Module that serializes zig structs into byte arrays.

const std = @import("std");

const native_endian = @import("builtin").target.cpu.arch.endian();

/// Entry point for recursive determination of serialization size of object
fn get_serialization_size(T: type) comptime_int {
    return get_serialization_size_recursive(0, T);
}

/// Entry point for recursive determination of byte array size at the end of serialization
pub fn get_serialization_array_size(T: type) comptime_int {
    // add a byte to account for the byte indicating data type index
    return get_serialization_size_recursive(0, T) + 1;
}

/// Returns the size of the tightly packed byte array that
/// a type will serialize into recursively
fn get_serialization_size_recursive(sum: comptime_int, T: type) comptime_int {
    var cur_sum = sum;
    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |@"struct"| {
            // struct so we should get the size of each of its fields
            // recursively as well
            inline for (@"struct".fields) |field| {
                cur_sum += get_serialization_size(field.type);
            }
        },
        .pointer => |pointer| {
            cur_sum += get_serialization_size(pointer.child);
        },
        else => {
            // simple data type we can get the size of
            cur_sum += @sizeOf(T);
        },
    }

    return cur_sum;
}

/// Ensure we are sending in big endian
fn serialize_endian(x: anytype) @TypeOf(x) {
    std.debug.assert(@typeInfo(@TypeOf(x)) == .int);
    switch (native_endian) {
        .big => {
            return x;
        },
        .little => {
            return @byteSwap(x);
        },
    }
}

/// Ensure we deserialize into whatever the native endian is
fn deserialize_endian(x: anytype) @TypeOf(x) {
    std.debug.assert(@typeInfo(@TypeOf(x)) == .int);
    switch (native_endian) {
        .big => {
            return x;
        },
        .little => {
            return @byteSwap(x);
        },
    }
}

/// Get the type of uint we can convert a float to
/// so we can do `@byteSwap` on it.
fn GetIntTypeFromFloatType(float_type: type) type {
    return switch (float_type) {
        f16 => u16,
        f32 => u32,
        f64 => u64,
        f128 => u128,
        else => @compileError("type of float not supported"),
    };
}

/// Handles serialization of int or float values
fn serialize_numeric(T: type, numeric_ptr: *const T, target_buffer: []u8) void {
    const numeric_type_info = @typeInfo(T);
    if (numeric_type_info != .int and numeric_type_info != .float) @compileError("the argument should be numeric");

    // if one byte, no need for endian correction
    if (@sizeOf(T) == 1) {
        target_buffer[0] = std.mem.toBytes(numeric_ptr.*)[0];
        return;
    }

    switch (numeric_type_info) {
        .float => {
            // if float first cast to uint then correct endian
            const IntType = GetIntTypeFromFloatType(T);
            const int_rep: IntType = @bitCast(numeric_ptr.*);
            @memcpy(target_buffer[0..], std.mem.asBytes(&serialize_endian(int_rep)));
        },
        .int => {
            // if int correct endian and write immidiately
            @memcpy(target_buffer[0..], std.mem.asBytes(&serialize_endian(numeric_ptr.*)));
        },
        else => unreachable,
    }
}

/// Handles the deserialization of int or float values
fn deserialize_numeric(TargetType: type, data: []const u8, target_field_ptr: *TargetType) void {
    if (@typeInfo(TargetType) != .int and @typeInfo(TargetType) != .float) @compileError("field type should be numeric");

    // if the target type is of size 1 byte, no need for endian correction
    if (@sizeOf(TargetType) == 1) {
        target_field_ptr.* = std.mem.bytesAsValue(TargetType, &data[0]).*;
        return;
    }

    switch (@typeInfo(TargetType)) {
        .float => {
            // if float first cast to uint, then correct endian
            const IntType = GetIntTypeFromFloatType(TargetType);
            const int_rep = std.mem.bytesAsValue(IntType, data.ptr);
            target_field_ptr.* = @bitCast(deserialize_endian(int_rep.*));
        },
        .int => {
            // directly correct endian
            const int_ptr = std.mem.bytesAsValue(TargetType, data.ptr);
            target_field_ptr.* = @bitCast(deserialize_endian(int_ptr.*));
        },
        else => unreachable,
    }
}

/// Serialize given value recursively into target slice
fn serialize_data(SourceType: type, target_slice: []u8, index: u32, source_object_ptr: *const SourceType) void {
    var cur_index = index;

    const source_type_info = @typeInfo(SourceType);
    const source_type_size = get_serialization_size(SourceType);

    switch (source_type_info) {
        .float, .int => {
            // handle endians
            serialize_numeric(SourceType, source_object_ptr, target_slice[cur_index .. cur_index + source_type_size]);
            cur_index += source_type_size;
        },
        .@"struct" => |@"struct"| {
            // go through each field of struct and serialize recursively
            const fields = @"struct".fields;

            inline for (fields) |field| {
                serialize_data(
                    @TypeOf(@field(source_object_ptr, field.name)),
                    target_slice,
                    cur_index,
                    &@field(source_object_ptr, field.name),
                );
                cur_index += get_serialization_size(field.type);
            }
        },
        .bool => {
            // just copy the byte
            target_slice[cur_index] = @intFromBool(source_object_ptr.*);
            cur_index += 1;
        },
        .pointer => |pointer| {
            serialize_data(
                pointer.child,
                target_slice,
                cur_index,
                source_object_ptr.*,
            );
            cur_index += get_serialization_size(pointer.child);
        },
        else => {
            @compileError("Type not supported");
        },
    }
}

/// Deserializes source byte slice into target
fn deserialize_data(TargetType: type, target_ptr: *TargetType, source_slice: []const u8, index: u32, allocator: ?std.mem.Allocator) !void {
    var cur_index = index;
    const target_info = @typeInfo(TargetType);
    const target_size = get_serialization_size(TargetType);

    switch (target_info) {
        .@"struct" => {
            // Go thorugh each field of the struct and deserialize recursively
            const fields = target_info.@"struct".fields;

            inline for (fields) |field| {
                const field_size = get_serialization_size(field.type);
                try deserialize_data(
                    @TypeOf(@field(target_ptr, field.name)),
                    &@field(target_ptr, field.name),
                    source_slice,
                    cur_index,
                    allocator,
                );
                cur_index += field_size;
            }
        },
        .int, .float => {
            // handle endians
            deserialize_numeric(
                TargetType,
                source_slice[cur_index .. cur_index + target_size],
                target_ptr,
            );
            cur_index += target_size;
        },
        .bool => {
            // just copy the byte into the field
            target_ptr.* = source_slice[cur_index] != 0;
            cur_index += 1;
        },
        .pointer => |pointer| {
            if (allocator) |alloc| {
                const new_ptr = try alloc.create(pointer.child);
                try deserialize_data(pointer.child, new_ptr, source_slice, cur_index, alloc);
                target_ptr.* = new_ptr;
            } else {
                @panic("structs with pointer fields can only be deserialized using deserialize_with_allocator");
            }
        },
        else => @compileError("unsuported type"),
    }
}

pub fn GenSerializer(comptime types: []const type) type {
    return struct {
        /// Returns the maximum size that can be serialized of the registed types
        pub fn get_max_serialization_size() comptime_int {
            var max: comptime_int = 0;
            inline for (types) |T| {
                max = @max(max, get_serialization_size(T));
            }
            return max;
        }

        /// Gets index of registered type
        pub fn get_index(T: type) u8 {
            inline for (types, 0..) |t, index| {
                if (t == T) {
                    return index;
                }
            }
            @compileError("Type not registered");
        }

        /// Entry point for recursive serialization.
        pub fn serialize(
            SourceType: type,
            target_slice: []u8,
            source_object_ptr: *const SourceType,
        ) void {
            std.debug.assert(target_slice.len >= get_serialization_array_size(SourceType));

            target_slice[0] = get_index(SourceType);
            serialize_data(SourceType, target_slice[1..], 0, source_object_ptr);
        }

        /// Entry point for recursive serialization.
        /// Allocates a buffer on the heap and returns it as a slice.
        pub fn serialize_with_allocator(
            SourceType: type,
            source_object_ptr: *const SourceType,
            allocator: std.mem.Allocator,
        ) ![]u8 {
            var target_slice = try allocator.alloc(u8, get_serialization_array_size(SourceType));

            target_slice[0] = get_index(SourceType);
            serialize_data(SourceType, target_slice[1..], 0, source_object_ptr);

            return target_slice;
        }

        /// Entry point for recursive deserialization.
        /// Deserializes the byte slice into a given target.
        pub fn deserialize(TargetStructType: type, target_struct_ptr: *TargetStructType, source_slice: []const u8) void {
            if (@typeInfo(TargetStructType) != .@"struct") @compileError("Argument should be a pointer to a struct type");
            std.debug.assert(get_serialization_array_size(TargetStructType) <= source_slice.len);

            deserialize_data(TargetStructType, target_struct_ptr, source_slice[1..], 0, null) catch unreachable;
        }

        /// Entry point for recursive deserialization.
        /// Deserializes the byte slice into a given target.
        /// Allocates the struct on the heap and returns a pointer to it.
        pub fn deserialize_with_allocator(TargetStructType: type, data: []const u8, allocator: std.mem.Allocator) !*TargetStructType {
            if (@typeInfo(TargetStructType) != .@"struct") @compileError("Argument should be a pointer to a struct type");
            std.debug.assert(get_serialization_array_size(TargetStructType) <= data.len);

            const target_struct_ptr = try allocator.create(TargetStructType);

            try deserialize_data(TargetStructType, target_struct_ptr, data[1..], 0, allocator);

            return target_struct_ptr;
        }

        /// Utility function to get the index form the first byte
        pub fn get_index_from_byte_array(array: []const u8) u8 {
            return array[0];
        }
    };
}

const TestVector = struct {
    x: f32,
    y: f32,
};

const TestStruct = struct {
    vector: TestVector,
    unsinged: u16,
    signed: i32,
    flag: bool,
    small: i2,
};

test "size" {
    try std.testing.expect(get_serialization_size(TestVector) == 8);
}

test "test serializer" {
    const Serializer = GenSerializer(&.{TestStruct});

    const struct_to_serialize = TestStruct{
        .vector = .{ .x = 10, .y = 20 },
        .flag = true,
        .signed = -50,
        .unsinged = 100,
        .small = 1,
    };

    var byte_array: [get_serialization_array_size(TestStruct)]u8 = undefined;
    Serializer.serialize(TestStruct, &byte_array, &struct_to_serialize);

    std.debug.print("\n{any}\n", .{byte_array});

    switch (byte_array[0]) {
        Serializer.get_index(TestStruct) => {
            var deserialized: TestStruct = undefined;
            Serializer.deserialize(TestStruct, &deserialized, &byte_array);

            try std.testing.expect(deserialized.vector.x == 10);
            try std.testing.expect(deserialized.vector.y == 20);
            try std.testing.expect(deserialized.flag);
            try std.testing.expect(deserialized.signed == -50);
            try std.testing.expect(deserialized.unsinged == 100);
            try std.testing.expect(deserialized.small == 1);
        },
        else => unreachable,
    }
}

test "alloc serializer" {
    const Serializer = GenSerializer(&.{TestStruct});

    const struct_to_serialize = TestStruct{
        .vector = .{ .x = 10, .y = 20 },
        .flag = true,
        .signed = -50,
        .unsinged = 100,
        .small = -1,
    };

    const allocator = std.testing.allocator;

    const byte_arr_slice = try Serializer.serialize_with_allocator(TestStruct, &struct_to_serialize, allocator);
    defer allocator.free(byte_arr_slice);

    std.debug.print("\n{any}\n", .{byte_arr_slice});

    const deserialized_ptr = try Serializer.deserialize_with_allocator(TestStruct, byte_arr_slice, allocator);
    defer allocator.destroy(deserialized_ptr);

    try std.testing.expect(deserialized_ptr.vector.x == 10);
    try std.testing.expect(deserialized_ptr.vector.y == 20);
    try std.testing.expect(deserialized_ptr.flag);
    try std.testing.expect(deserialized_ptr.signed == -50);
    try std.testing.expect(deserialized_ptr.unsinged == 100);
    try std.testing.expect(deserialized_ptr.small == -1);
}

const TestStructWithPointer = struct {
    vector1_ptr: *TestVector,
    vector2_ptr: *TestVector,

    pub fn deinit(self: *TestStructWithPointer, allocator: std.mem.Allocator) void {
        allocator.destroy(self.vector1_ptr);
        allocator.destroy(self.vector2_ptr);
        allocator.destroy(self);
    }
};

test "struct with pointer" {
    const Serializer = GenSerializer(&.{TestStructWithPointer});

    var vec1 = TestVector{ .x = 10, .y = 20 };
    var vec2 = TestVector{ .x = 30, .y = 40 };
    const struct_to_serialize = TestStructWithPointer{
        .vector1_ptr = &vec1,
        .vector2_ptr = &vec2,
    };

    var serialization_buffer: [get_serialization_array_size(TestStructWithPointer)]u8 = undefined;
    Serializer.serialize(TestStructWithPointer, &serialization_buffer, &struct_to_serialize);

    std.debug.print("\n{any}\n", .{serialization_buffer});

    const allocator = std.testing.allocator;
    const deser_ptr = try Serializer.deserialize_with_allocator(TestStructWithPointer, &serialization_buffer, allocator);
    defer deser_ptr.deinit(allocator);

    try std.testing.expect(deser_ptr.vector1_ptr.x == 10);
    try std.testing.expect(deser_ptr.vector1_ptr.y == 20);
    try std.testing.expect(deser_ptr.vector2_ptr.x == 30);
    try std.testing.expect(deser_ptr.vector2_ptr.y == 40);
}

const SecondType = struct {
    num: u32,
};

test "multiple types" {
    const Serializer = GenSerializer(&.{ TestVector, SecondType });

    const struct_to_serialize = TestVector{ .x = 10, .y = 20 };
    const struct_to_serialize2 = SecondType{ .num = 5 };

    var byte_array: [get_serialization_array_size(TestVector)]u8 = undefined;
    Serializer.serialize(TestVector, &byte_array, &struct_to_serialize);

    var byte_array2: [get_serialization_array_size(SecondType)]u8 = undefined;
    Serializer.serialize(SecondType, &byte_array2, &struct_to_serialize2);

    const arrays: [2][]const u8 = .{ &byte_array, &byte_array2 };

    for (arrays) |array| {
        switch (Serializer.get_index_from_byte_array(array)) {
            Serializer.get_index(TestVector) => {
                var deserialized: TestVector = undefined;
                Serializer.deserialize(TestVector, &deserialized, &byte_array);

                try std.testing.expect(deserialized.x == 10);
                try std.testing.expect(deserialized.y == 20);
            },
            Serializer.get_index(SecondType) => {
                var deserialized: SecondType = undefined;
                Serializer.deserialize(SecondType, &deserialized, &byte_array2);

                try std.testing.expect(deserialized.num == 5);
            },
            else => unreachable,
        }
    }
}
