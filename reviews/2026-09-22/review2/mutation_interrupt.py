import os
import pathlib
import signal
import subprocess
import tempfile
import time

source = pathlib.Path(__file__).resolve().parents[3]
failures = 0
with tempfile.TemporaryDirectory(prefix='review2-interrupt-') as temporary:
    scratch = pathlib.Path(temporary)
    wrapper = scratch / 'bin'
    wrapper.mkdir()
    marker = scratch / 'vvp-started'
    fake_vvp = wrapper / 'vvp'
    fake_vvp.write_text('#!/bin/sh\n: > "$REVIEW_MARKER"\nexec sleep 30\n')
    fake_vvp.chmod(0o755)
    env = dict(os.environ, PATH=str(wrapper) + os.pathsep + os.environ['PATH'],
               REVIEW_MARKER=str(marker))
    archive = subprocess.check_output(['git', 'archive', 'HEAD'], cwd=source)
    for name in ['i2c', 'spi', 'fbuf']:
        checkout = scratch / name
        checkout.mkdir()
        subprocess.run(['tar', '-x', '-C', str(checkout)], input=archive, check=True)
        (checkout / 'sim').mkdir(exist_ok=True)
        tracked = [p for directory in ['rtl', 'firmware']
                   for p in (checkout / directory).glob('*') if p.is_file()]
        before = {p: p.read_bytes() for p in tracked}
        marker.unlink(missing_ok=True)
        process = subprocess.Popen(['bash', f'tb/mutate_{name}_tb.sh'], cwd=checkout,
                                   env=env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            if not marker.exists():
                if process.poll() is not None:
                    print(process.communicate()[0].decode())
                raise RuntimeError(f'{name}: never reached the mutated simulation')
            # This process group was created above solely for this probe.
            os.killpg(process.pid, signal.SIGTERM)
            output, _ = process.communicate(timeout=10)
            changed = [str(p.relative_to(checkout)) for p, content in before.items()
                       if p.read_bytes() != content]
            print(f'{name}: interrupted status={process.returncode}; changed={changed}')
            print(output.decode().strip())
            failures += bool(changed)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)

if failures:
    raise SystemExit(f"FAIL: {failures} mutation harnesses left source files changed")
