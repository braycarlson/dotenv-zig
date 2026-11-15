# dotenv-zig

A .env file reader for Zig. The format has no specification, so python-dotenv serves as the reference and a conformance file generated from it checks the reader. The library exposes a pull scanner and a decoded document, with optional variable interpolation and a choice of whether a file overrides the existing environment. A line that is not a binding is recorded with its position rather than failing the file.
