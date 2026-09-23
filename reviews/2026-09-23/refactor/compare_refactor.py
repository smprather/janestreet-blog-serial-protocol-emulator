#!/usr/bin/env python3
"""Compare pre-refactor RTL, TBs and firmware with this checkout. Read-only."""

import ast
import difflib
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[3]
BASE = '2cc0f03'
RENAMES = {
    'tb_pe_uart_soc': 'tb_pe_soc_uart',
    'tb_pe_i2c_soc': 'tb_pe_soc_i2c',
    'tb_pe_spi_soc': 'tb_pe_soc_spi',
    'tb_pe_tick_status': 'tb_pe_soc_tick',
    'pe_uart_soc': 'pe_soc',
    'tb/run_all.sh': 'regress/run_all.sh',
    'rtl/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v':
        'rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v',
}

def old(path):
    return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT).decode()

def rename(value):
    for before, after in RENAMES.items():
        value = value.replace(before, after)
    return value

def without_comments(value):
    return re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda match: match[0] if match[0].startswith('"') else ' ', value)

def modules(value):
    value = without_comments(value)
    result = {}
    for match in re.finditer(r'(?ms)^\s*module\s+(\w+)\b.*?\bendmodule', value):
        tokens = re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\S', match[0])
        result[match[1]] = tokens
    return result

failures = 0
for directory in ('rtl', 'tb'):
    baseline = {}
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASE, directory], cwd=ROOT).decode().splitlines()
    for name in names:
        if name.endswith('.v'):
            baseline.update(modules(rename(old(name))))
    current = {}
    for path in (ROOT / directory).rglob('*.v'):
        current.update(modules(path.read_text()))
    changed = [name for name in baseline.keys() | current.keys()
               if baseline.get(name) != current.get(name)]
    print(f'{directory}: {len(baseline)} -> {len(current)} modules; changed token streams after intended renames: {changed}')
    failures += bool(changed)
    for name in changed:
        print('\n'.join(difflib.unified_diff(baseline.get(name, []), current.get(name, []), n=3))[:2500])

# Module comparison alone omits attributes and compilation directives.
# Preserve these per source file, allowing the documented moves. Empty codec
# headers disappear when comments are removed; no directives were redistributed.
def outside_modules(value):
    value = without_comments(value)
    value = re.sub(r'(?ms)^\s*module\s+\w+\b.*?\bendmodule', '', value)
    return ' '.join(value.split())

baseline_outside = {}
current_outside = {}
for directory in ('rtl', 'tb'):
    names = subprocess.check_output(
        ['git', 'ls-tree', '-r', '--name-only', BASE, directory], cwd=ROOT
    ).decode().splitlines()
    for name in names:
        if name.endswith('.v'):
            value = outside_modules(rename(old(name)))
            if value:
                baseline_outside[rename(name)] = value
    for path in (ROOT / directory).rglob('*.v'):
        value = outside_modules(path.read_text())
        if value:
            current_outside[str(path.relative_to(ROOT))] = value
same = baseline_outside == current_outside
print(f'File-level directives/attributes preserved per renamed file: {same}')
failures += not same

class StripDocstrings(ast.NodeTransformer):
    def generic_visit(self, node):
        super().generic_visit(node)
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.body and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant) and isinstance(node.body[0].value.value, str):
                node.body.pop(0)
        return node

for name in ('peasm.py', 'peemu.py'):
    a = ast.dump(StripDocstrings().visit(ast.parse(old('tools/' + name))), include_attributes=False)
    b = ast.dump(StripDocstrings().visit(ast.parse((ROOT / 'tools/fw' / name).read_text())), include_attributes=False)
    print(f'{name}: executable AST identical: {a == b}')
    failures += a != b

for path in sorted((ROOT / 'firmware').glob('*.hex')):
    same = old(str(path.relative_to(ROOT))).encode() == path.read_bytes()
    print(f'{path.name}: image byte-identical: {same}')
    failures += not same

raise SystemExit(1 if failures else 0)
