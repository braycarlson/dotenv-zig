const document_module = @import("document.zig");
const scanner_module = @import("scanner.zig");
const text_module = @import("text.zig");

pub const Capacity = document_module.Capacity;
pub const CapacityError = document_module.CapacityError;
pub const DecodeError = text_module.DecodeError;
pub const DecodeOptions = text_module.DecodeOptions;
pub const Document = document_module.Document;
pub const DocumentType = document_module.DocumentType;
pub const Entry = document_module.Entry;
pub const Error = document_module.Error;
pub const Failures = document_module.Failures;
pub const Options = document_module.Options;
pub const Position = text_module.Position;
pub const Scanner = scanner_module.Scanner;
pub const Statement = scanner_module.Statement;
pub const Storage = document_module.Storage;
pub const SyntaxError = document_module.SyntaxError;
pub const Variable = document_module.Variable;
pub const Variables = document_module.Variables;

pub const decode = text_module.decode;
pub const message = document_module.message;

pub const limits = struct {
    pub const source_bytes_max: u32 = text_module.source_bytes_max;
};
