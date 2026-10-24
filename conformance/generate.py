from __future__ import annotations

import json
import os
import random
import tempfile

from pathlib import Path
from types import MappingProxyType
from typing import TYPE_CHECKING
from unittest import mock

from dotenv.main import DotEnv, load_dotenv
from dotenv.parser import parse_stream
from dotenv.version import __version__

if TYPE_CHECKING:
    from collections.abc import Mapping


BINARY_PIECE_COUNT_MAX = 8
ENVIRONMENT_EMPTY = MappingProxyType({})
ORACLE_VERSION = '1.2.1'
PROBABILITY_CLOSED = 0.85
PROBABILITY_INTERPOLATE = 0.85
PROBABILITY_INVALID = 0.15
PROBABILITY_OVERRIDE = 0.5
PROBABILITY_SOUP = 0.25
RANDOM_BINARY_CASE_COUNT = 80
RANDOM_CASE_COUNT = 600
RANDOM_SEED = 0x5EED
SOURCE_LINE_COUNT_MAX = 8
SUITE_PATH = Path(__file__).parent / 'python_dotenv.json'

UPSTREAM_PARSER_INPUTS = (
    '',
    'a=b',
    "'a'=b",
    '[=b',
    ' a = b ',
    'export a=b',
    " export 'a'=b",
    '# a=b',
    'a=b#c',
    'a=b #c',
    'a=b\t#c',
    'a=b c',
    'a=b\tc',
    'a=b  c',
    'a=b\u00a0 c',
    'a=b c ',
    "a='b c '",
    'a="b c "',
    'export export_a=1',
    'export port=8000',
    'a="b\nc"',
    "a='b\nc'",
    'a="b\\nc"',
    "a='b\\nc'",
    'a="b\\"c"',
    "a='b\\'c'",
    'a=\u00e0',
    'a="\u00e0"',
    'no_value_var',
    'a: b',
    'a=b\nc=d',
    'a=b\rc=d',
    'a=b\r\nc=d',
    'a=\nb=c',
    '\n\n',
    'a=b\n\n',
    'a=b\n\nc=d',
    'a="\nb=c',
    '# comment\na="b\nc"\nd=e\n',
    'a=b\n# comment 1',
    '# comment 1\n# comment 2',
    'uglyKey[%$="S3cr3t_P4ssw#rD" #\na=b',
)

UPSTREAM_INTERPOLATION_CASES = (
    ({'b': 'c'}, 'a=$b', False),
    ({'b': 'c'}, 'a=$b', True),
    ({'b': 'c'}, 'a=${b}', False),
    ({'b': 'c'}, 'a=${b}', True),
    ({'b': 'c'}, 'a=${b:-d}', False),
    ({'b': 'c'}, 'a=${b:-d}', True),
    ({}, 'b=c\na=${b}', True),
    ({}, 'a=${b}', True),
    ({}, 'a=${b:-d}', True),
    ({'b': 'c'}, 'a="${b}"', True),
    ({'b': 'c'}, "a='${b}'", True),
    ({'b': 'c'}, 'a=x${b}y', True),
    ({'a': 'b'}, 'a=${a}', True),
    ({}, 'a=${a}', True),
    ({'a': 'b'}, 'a=${a:-c}', True),
    ({}, 'a=${a:-c}', True),
    ({'b': 'c'}, 'a=${b}${b}', True),
    ({'b': 'c'}, 'b=d\na=${b}', True),
    ({}, 'a=b\na=c\nd=${a}', True),
    ({}, 'a=b\nc=${a}\nd=e\nc=${d}', True),
)

UPSTREAM_VARIABLE_VALUES = (
    '',
    'a',
    '${a}',
    '${a:-b}',
    '${a}${b}',
    'a${b}c${d}e',
)

EDGE_CASES = (
    ('escaped double quote', 'PASSWORD="a\\"b"\n', {}),
    ('escape sequence in double quotes', 'MESSAGE="line1\\nline2"\n', {}),
    ('multi-line double-quoted value', 'CERTIFICATE="first\nsecond"\nNEXT=after\n', {}),
    ('interpolation from the file', 'USER=example\nURL=postgres://${USER}@db/app\n', {}),
    ('interpolation with default', 'HOST=${UNSET_HOST:-localhost}\n', {}),
    ('tab before comment', 'NAME=app\t# comment\n', {}),
    ('escaped single quote', "GREETING='it\\'s'\n", {}),
    ('junk after closing quote', 'NAME="app"junk\n', {}),
    ('dash in key', 'MY-KEY=1\n', {}),
    ('key without equals', 'FLAG\nOTHER=1\n', {}),
    ('crlf in double quotes', 'A="1\r\n2"\r\nB=3\r\n', {}),
    ('lone carriage return terminator', 'A=1\rB=2\r', {}),
    ('lone carriage return in quotes', 'A="1\r2"\n', {}),
    ('byte order mark before a key', '\ufeffA=1\nB=2\n', {}),
    ('byte order mark before a comment', '\ufeff# c\nB=2\n', {}),
    ('equals then hash', 'A= #comment\nB=x #c\n', {}),
    ('no-break space before hash', 'A=x\u00a0#c\n', {}),
    ('no-break space after export', 'export\u00a0A=1\n', {}),
    ('no-break space in key', 'A\u00a0B=1\n', {}),
    ('vertical tab and form feed', 'A=x\x0b\nB=y\x0c#c\n', {}),
    ('line separator inside a value', 'A=x\u2028y\nB=z\u2028#c\n', {}),
    ('backtrack to a trailing pair', 'A="a\\"\nB=2\n', {}),
    ('backtrack to the last of two pairs', 'A="a\\"b\\"\nC=3\n', {}),
    ('escaped backslash then quote', 'A="a\\\\" # c\nX="y"\n', {}),
    ('single quote backtrack', "A='a\\'\nB=2\n", {}),
    ('defaults and malformed references', 'A=${UNSET:-}\nB=${UNSET:-d}\nC=${UNSET:x}\n', {}),
    ('dollar before a reference', 'A=1\nB=$${A}\n', {}),
    ('nested reference', 'A=1\nB=${A${A}}\n', {}),
    ('reference to a key without value', 'A\nB=${A:-d}\n', {}),
    ('self reference twice', 'A=${A}x\nA=${A}y\n', {'A': 'env'}),
    ('error lines', 'A=1\n\n"bad\nB="ok"x\nC=3\n', {}),
    ('quoted key across lines', "'a\nb'=1\n", {}),
    ('empty quoted key', "''=1\nB=2\n", {}),
    ('export alone and malformed', 'export\nexport  =1\nexport #c\nexportA=1\n', {}),
    ('export at end of file', 'A=1\nexport ', {}),
    ('junk after a key without value', 'KEY junk\nK2 # c\n', {}),
    ('every escape', "A=\"\\a\\b\\f\\n\\r\\t\\v\\\\\\x\\$\"\nB='\\\\\\'\\n'\n", {}),
    ('unterminated quote cut by a merge', 'NAME=app\nCERT="first\nDEBUG=False\nKEY="abc"\n', {}),
    ('reference to the environment', 'A=${HOME_DIR}/x\n', {'HOME_DIR': '/home/a'}),
    ('reference with empty name', 'A=${}\nB=${:-z}\n', {}),
    ('reference spanning lines', 'A="${B\nC}"\n', {'B\nC': 'odd'}),
    ('quotes inside a bare key', 'K"x"=1\n', {}),
    ('hash inside a bare key', 'A#B=1\n', {}),
    ('equals inside a quoted key', "'a=b'=1\n", {}),
    ('nul byte in a value', 'A=x\x00y\nB="\x00"\n', {}),
    ('empty values', 'A=\nB=""\nC=\'\'\nD=   \nE= # c\n', {}),
    ('value ends at end of file', 'A=x', {}),
    ('quoted value at end of file', 'A="x"', {}),
    ('lone quote at end of file', 'A="', {}),
    ('whitespace only file', ' \t\n\u3000\n', {}),
    ('comment then blank lines then a key', '# c\n\n\nA=1', {}),
    ('duplicate keys keep the first position', 'A=1\nB=2\nA=3\n', {}),
    ('key that looks like export', "export=1\nexport A = 'x' # y\n=\n", {}),
    ('multibyte characters', 'K\u00e9=\u4e2d\u6587\nV="\U0001f600"\n', {}),
    ('environment beats the file without override', 'A=file\nB=${A}\n', {'A': 'env'}),
    ('next line character', 'A=x\x85#c\nB\x85=1\nC=\x85y\x85\n', {}),
    ('information separators', 'A=x\x1c#c\nB=y\x1f\n\x1eC=1\n\x1dD\n', {}),
    ('paragraph separator', 'A="x\u2029y"\nB=\u2029\n\u2029C=1\n', {}),
    ('ogham space mark', 'A=x\u1680#c\nexport\u1680B=2\n', {}),
    ('zero width space is not whitespace', 'A=x\u200b#c\n\u200bB=1\n', {}),
    ('byte order mark inside a value', 'A=x\ufeff #c\n', {}),
)

FRAGMENTS = (
    'A',
    'B',
    'C',
    'B_2',
    'a.b',
    'x-y',
    "'A'",
    "'q k'",
    'export ',
    'export',
    '=',
    ' = ',
    ' ',
    '\t',
    '\u00a0',
    '\u3000',
    '\x0b',
    '"',
    "'",
    '\\',
    '\\"',
    "\\'",
    '\\\\',
    '\\n',
    '\\t',
    '\\x',
    '#',
    ' #',
    '${A}',
    '${B:-d}',
    '${A:x}',
    '${',
    '}',
    ':-',
    '$',
    '\u00e9',
    '\u4e2d',
    '\U0001f600',
    'value',
    '1',
    '\n',
    '\r\n',
    '\r',
)

KEYS = (
    'A',
    'B',
    'C',
    'B_2',
    'a.b',
    'x-y',
    '1K',
    "'A'",
    "'q k'",
    "'a=b'",
    'export',
    '\u00c9',
    '',
)

BARE_ALPHABET = (
    'a',
    'Z',
    '1',
    ' ',
    '#',
    '\t',
    '$',
    '{',
    '}',
    '\\',
    '"',
    "'",
    '\u00e9',
    '\u00a0',
    ':',
    '-',
)

INVALID_BYTES = (
    b'\x80',
    b'\xbf',
    b'\xc0\xaf',
    b'\xc3',
    b'\xe0\x80\xaf',
    b'\xed\xa0\x80',
    b'\xf4\x90\x80\x80',
    b'\xf5',
    b'\xff',
)

QUOTED_ALPHABET = (
    'a',
    ' ',
    '#',
    '\n',
    '\\n',
    '\\"',
    "\\'",
    '\\\\',
    '\\x',
    '"',
    "'",
    '${A}',
    '\u00e9',
    '\r\n',
)

REFERENCES = (
    '${A}',
    '${B:-d}',
    '${A:x}',
    '$${A}',
    '${A${B}}',
    '${:-z}',
    '${}',
    '${C:-}',
    '$A',
)

ENDINGS = ('\n', '\n', '\n', '\r\n', '\r', '')
PREFIXES = ('', '', '', ' ', '\t', 'export ', 'export\t', '\u00a0', '\ufeff')
SEPARATORS = ('=', '=', '=', ' = ', '=\t', ' =', ':', '')
SHAPES = ('bare', 'double', 'single', 'references', 'empty')
SUFFIXES = ('', '', '', ' ', ' # c', '#c', '\t#c', ' junk', '\u00a0#c', ' \\')
VALID_SEQUENCES = ('a', '=', '\n', '\u00e9', '\u4e2d', '\U0001f600', '\ufeff')
VARIABLE_NAMES = ('A', 'B', 'C', 'B_2')
VARIABLE_VALUES = ('env', '', '${A}', 'x y', '\u00e9', 'a=b')


def case_build(
    directory: Path,
    name: str,
    data: bytes,
    environment: Mapping[str, str],
    *,
    interpolate: bool = True,
    override: bool = True,
) -> dict[str, object]:
    case: dict[str, object] = {
        'environment': dict(environment),
        'interpolate': interpolate,
        'name': name,
        'override': override,
    }

    try:
        case['source'] = data.decode('utf-8')
    except UnicodeDecodeError:
        case['source_hex'] = data.hex()

    path = directory / 'case.env'

    path.write_bytes(data)

    try:
        statements = statements_read(path)
    except UnicodeDecodeError:
        case['outcome'] = 'utf8_invalid'
        return case

    with mock.patch.dict(os.environ, environment, clear=True):
        dotenv = DotEnv(path, encoding='utf-8', interpolate=interpolate, override=override)
        values = dotenv.dict()

    case['loaded'] = loaded_read(
        path,
        environment,
        list(values),
        interpolate=interpolate,
        override=override,
    )

    case['outcome'] = 'parsed'
    case['statements'] = statements
    case['values'] = [[key, value] for key, value in values.items()]

    return case


def loaded_read(
    path: Path,
    environment: Mapping[str, str],
    keys: list[str],
    *,
    interpolate: bool,
    override: bool,
) -> list[list[object]] | None:
    with mock.patch.dict(os.environ, environment, clear=True):
        try:
            load_dotenv(path, encoding='utf-8', interpolate=interpolate, override=override)
        except ValueError:
            return None

        return [[key, os.environ.get(key)] for key in keys]


def statements_read(path: Path) -> list[list[object]]:
    with path.open(encoding='utf-8') as stream:
        bindings = list(parse_stream(stream))

    statements = []

    for binding in bindings:
        if binding.error:
            kind = 'failure'
        elif binding.key is None:
            kind = 'trivia'
        else:
            kind = 'binding'

        original = binding.original

        statements.append([kind, binding.key, binding.value, original.string, original.line])

    return statements


def cases_fixed(directory: Path) -> list[dict[str, object]]:
    cases = []

    for index, source in enumerate(UPSTREAM_PARSER_INPUTS):
        name = f'upstream parser {index}'

        cases.append(case_build(directory, name, source.encode(), ENVIRONMENT_EMPTY))

    for index, (environment, source, interpolate) in enumerate(UPSTREAM_INTERPOLATION_CASES):
        name = f'upstream interpolation {index}'

        cases.append(
            case_build(
                directory,
                name,
                source.encode(),
                environment,
                interpolate=interpolate,
            ),
        )

    for index, value in enumerate(UPSTREAM_VARIABLE_VALUES):
        name = f'upstream variables {index}'
        environment = {'a': '1', 'b': '2', 'd': '4'}

        cases.append(case_build(directory, name, f'x={value}\n'.encode(), environment))

    for name, source, environment in EDGE_CASES:
        for interpolate in (True, False):
            for override in (True, False):
                label = f'{name} (interpolate={interpolate}, override={override})'

                cases.append(
                    case_build(
                        directory,
                        label,
                        source.encode(),
                        environment,
                        interpolate=interpolate,
                        override=override,
                    ),
                )

    for index, data in enumerate(INVALID_BYTES):
        name = f'invalid utf-8 {index}'

        cases.append(case_build(directory, name, b'A=1\nB=' + data + b'\n', ENVIRONMENT_EMPTY))

    return cases


def source_random(generator: random.Random) -> str:
    lines = []

    for _ in range(generator.randint(0, SOURCE_LINE_COUNT_MAX)):
        if generator.random() < PROBABILITY_SOUP:
            count = generator.randint(1, 10)
            line = ''.join(generator.choice(FRAGMENTS) for _ in range(count))
        else:
            line = line_random(generator)

        lines.append(line + generator.choice(ENDINGS))

    return ''.join(lines)


def line_random(generator: random.Random) -> str:
    prefix = generator.choice(PREFIXES)
    key = generator.choice(KEYS)
    separator = generator.choice(SEPARATORS)
    shape = generator.choice(SHAPES)

    if shape == 'bare':
        count = generator.randint(0, 8)
        value = ''.join(generator.choice(BARE_ALPHABET) for _ in range(count))
    elif shape in ('double', 'single'):
        quote = '"' if shape == 'double' else "'"
        count = generator.randint(0, 6)
        body = ''.join(generator.choice(QUOTED_ALPHABET) for _ in range(count))
        close = quote if generator.random() < PROBABILITY_CLOSED else ''
        value = quote + body + close
    elif shape == 'references':
        count = generator.randint(1, 4)
        value = ''.join(generator.choice([*REFERENCES, 'x', ' ']) for _ in range(count))
    else:
        value = ''

    return prefix + key + separator + value + generator.choice(SUFFIXES)


def environment_random(generator: random.Random) -> dict[str, str]:
    count = generator.randint(0, len(VARIABLE_NAMES))
    names = generator.sample(VARIABLE_NAMES, count)

    return {name: generator.choice(VARIABLE_VALUES) for name in names}


def binary_random(generator: random.Random) -> bytes:
    pieces = []

    for _ in range(generator.randint(1, BINARY_PIECE_COUNT_MAX)):
        if generator.random() < PROBABILITY_INVALID:
            pieces.append(generator.choice(INVALID_BYTES))
        else:
            pieces.append(generator.choice(VALID_SEQUENCES).encode())

    return b''.join(pieces)


def cases_random(
    directory: Path,
    *,
    count: int,
    binary_count: int,
    seed: int,
) -> list[dict[str, object]]:
    generator = random.Random(seed)
    cases = []

    for index in range(count):
        source = source_random(generator)
        environment = environment_random(generator)
        interpolate = generator.random() < PROBABILITY_INTERPOLATE
        override = generator.random() < PROBABILITY_OVERRIDE

        cases.append(
            case_build(
                directory,
                f'random {index}',
                source.encode(),
                environment,
                interpolate=interpolate,
                override=override,
            ),
        )

    for index in range(binary_count):
        name = f'random bytes {index}'
        data = binary_random(generator)

        cases.append(case_build(directory, name, data, ENVIRONMENT_EMPTY))

    return cases


def suite_write(path: Path, cases: list[dict[str, object]]) -> None:
    lines = [json.dumps(case, ensure_ascii=True, sort_keys=True) for case in cases]
    body = ',\n'.join(f'    {line}' for line in lines)
    oracle = json.dumps(f'python-dotenv {__version__}')
    text = f'{{\n  "oracle": {oracle},\n  "cases": [\n{body}\n  ]\n}}\n'

    path.write_text(text, encoding='utf-8')


def suite_generate(path: Path, *, count: int, binary_count: int, seed: int) -> None:
    if __version__ != ORACLE_VERSION:
        message = f'The suite is generated from python-dotenv {ORACLE_VERSION}, not {__version__}'
        raise RuntimeError(message)

    with tempfile.TemporaryDirectory(prefix='dotenv-conformance-') as name:
        directory = Path(name)
        fixed = cases_fixed(directory)
        generated = cases_random(directory, count=count, binary_count=binary_count, seed=seed)
        cases = fixed + generated

    suite_write(path, cases)


if __name__ == '__main__':
    suite_generate(
        SUITE_PATH,
        count=RANDOM_CASE_COUNT,
        binary_count=RANDOM_BINARY_CASE_COUNT,
        seed=RANDOM_SEED,
    )
