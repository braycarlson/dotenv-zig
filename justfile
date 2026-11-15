set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact for Linux and Windows')]
check:
    zig build check

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Run the python-dotenv suite: just conformance [other suite files]')]
conformance *arguments:
    zig build conformance -- {{ arguments }}

[doc('Build and run the example')]
example:
    zig build example

[doc('Format every Zig source file and every Python file')]
fmt:
    zig fmt build.zig examples src
    uvx ruff format conformance

[doc('Run a fuzzer: just fuzz <fuzzer> [seed]')]
fuzz *arguments:
    zig build fuzz -- {{ arguments }}

[doc('Lint every Zig file with tigerstyle-lsp, and the Python files with ruff')]
lint:
    tigerstyle-lsp check build.zig examples src --format concise
    uvx ruff check conformance
    uvx ruff format --check conformance

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Regenerate conformance/python_dotenv.json from python-dotenv 1.2.1')]
suite:
    uv run --no-project --with python-dotenv==1.2.1 python conformance/generate.py

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just test-unit [filter]')]
test-unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
