#!/usr/bin/env python3
"""Render a Jinja2 template using the process environment as its context.

    lib/render.py <template> [<output>]

Writes to <output>, or to stdout when it is omitted. Parent directories of
<output> are created as needed.

This replaces j2cli, which is unmaintained and does not run on a current
Python: it imports `imp` (removed in 3.12) and `pkg_resources` (dropped from
setuptools 81). The only dependency here is Jinja2 itself, packaged as
python3-jinja2 on Debian and Ubuntu.

The Jinja environment deliberately matches j2cli's "env mode" so that no
template output changes:

  undefined=StrictUndefined  an unset variable is an error, not an empty
                             string. This is the property the whole design
                             leans on -- a typo must abort the install rather
                             than silently write a config with a hole in it.
  keep_trailing_newline      preserve the template's final newline.
  autoescape off             these are config files, not HTML.
  loader on the template's directory, so {% include %} resolves as before.
"""

import argparse
import os
import sys

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
    from jinja2 import TemplateSyntaxError, UndefinedError
except ModuleNotFoundError:
    sys.exit(
        "render.py: Jinja2 is not installed.\n"
        "  Debian/Ubuntu: apt install python3-jinja2\n"
        "  otherwise:     pip install Jinja2"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="render.py",
        description="Render a Jinja2 template with environment variables as context.",
    )
    parser.add_argument("template", help="path to the .j2 template")
    parser.add_argument(
        "output", nargs="?", help="path to write to (default: standard output)"
    )
    args = parser.parse_args()

    if not os.path.isfile(args.template):
        return fail(f"template not found: {args.template}")

    directory, name = os.path.split(os.path.abspath(args.template))
    env = Environment(
        loader=FileSystemLoader(directory),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        autoescape=False,
        extensions=["jinja2.ext.do", "jinja2.ext.loopcontrols"],
    )

    try:
        rendered = env.get_template(name).render(dict(os.environ))
    except UndefinedError as exc:
        # The common case by far: a variable nothing exported. Name the template
        # so the failure is actionable without a traceback.
        return fail(f"{args.template}: {exc}")
    except TemplateSyntaxError as exc:
        return fail(f"{args.template}:{exc.lineno}: {exc.message}")

    if args.output is None:
        sys.stdout.write(rendered)
        return 0

    parent = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(parent, exist_ok=True)
    try:
        with open(args.output, "w") as handle:
            handle.write(rendered)
    except OSError as exc:
        return fail(f"cannot write {args.output}: {exc.strerror}")

    return 0


def fail(message: str) -> int:
    print(f"render.py: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
