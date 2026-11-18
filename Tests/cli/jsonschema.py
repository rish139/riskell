#!/usr/bin/env python3 -I
"""Checks one JSON document against one of schemas/*.schema.json, with nothing but python3.

    python3 -I Tests/cli/jsonschema.py SCHEMA INSTANCE

Exit 0 when INSTANCE validates, 1 with one line per finding (`path: what`), 2 when it cannot read a file. The schemas use
a subset of JSON Schema 2020-12 just large enough to describe the CLI's output: type, required, properties,
additionalProperties (a boolean), items, enum, const, pattern, minLength, minimum, maximum, minItems, uniqueItems, allOf,
anyOf, oneOf and if/then/else, plus the annotations $schema, $id, title, description and examples. A keyword outside
that list is a finding of its own, so a rule written into a schema can never be one this check quietly did not run.

The contract's one rule about the schema itself lives here too: the object's "schema" and the file's "$id" are the same
string. (`riskell-setup --doctor` prints its schema as the number 1, and "1" is what its file is called.)
"""

import json
import re
import sys

KEYWORDS = {
    "type", "required", "properties", "additionalProperties", "items", "enum", "const", "pattern", "minLength",
    "minimum", "maximum", "minItems", "uniqueItems", "allOf", "anyOf", "oneOf", "if", "then", "else",
}
ANNOTATIONS = {"$schema", "$id", "$comment", "title", "description", "examples", "default", "deprecated"}


def kind(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def validate(value, schema, at, out):
    """Every way `value` does not match `schema`, as (path, what) pairs appended to `out`."""
    if schema is True or schema == {}:
        return
    if schema is False:
        out.append((at, "nothing is allowed here"))
        return

    for keyword in schema:
        if keyword not in KEYWORDS and keyword not in ANNOTATIONS:
            out.append((at, 'the schema uses "%s", which this checker does not know' % keyword))

    types = schema.get("type")
    if types is not None:
        wanted = types if isinstance(types, list) else [types]
        if kind(value) not in wanted and not (kind(value) == "integer" and "number" in wanted):
            out.append((at, "expected %s, got %s" % (" or ".join(wanted), kind(value))))
            return

    if "const" in schema and value != schema["const"]:
        out.append((at, "expected %r, got %r" % (schema["const"], value)))
    if "enum" in schema and value not in schema["enum"]:
        out.append((at, "expected one of %r, got %r" % (schema["enum"], value)))

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            out.append((at, "shorter than %d characters" % schema["minLength"]))
        if "pattern" in schema and not re.search(schema["pattern"], value):
            out.append((at, "%r does not match %s" % (value, schema["pattern"])))

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            out.append((at, "%r is below %r" % (value, schema["minimum"])))
        if "maximum" in schema and value > schema["maximum"]:
            out.append((at, "%r is above %r" % (value, schema["maximum"])))

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            out.append((at, "%d items, at least %d expected" % (len(value), schema["minItems"])))
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            out.append((at, "the items are not all different"))
        if "items" in schema:
            for i, item in enumerate(value):
                validate(item, schema["items"], "%s[%d]" % (at, i), out)

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                out.append((at, 'no "%s"' % key))
        properties = schema.get("properties", {})
        for key, item in value.items():
            child = key if not at else "%s.%s" % (at, key)
            if key in properties:
                validate(item, properties[key], child, out)
            elif schema.get("additionalProperties", True) is False:
                out.append((at, 'unexpected "%s"' % key))
            elif isinstance(schema.get("additionalProperties"), dict):
                validate(item, schema["additionalProperties"], child, out)

    for subschema in schema.get("allOf", []):
        validate(value, subschema, at, out)
    for keyword in ("anyOf", "oneOf"):
        if keyword in schema:
            matched = 0
            for subschema in schema[keyword]:
                probe = []
                validate(value, subschema, at, probe)
                if not probe:
                    matched += 1
            if matched == 0 or (keyword == "oneOf" and matched > 1):
                out.append((at, "matched %d of the %s alternatives" % (matched, keyword)))
    if "if" in schema:
        probe = []
        validate(value, schema["if"], at, probe)
        if not probe:
            validate(value, schema.get("then", True), at, out)
        else:
            validate(value, schema.get("else", True), at, out)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: jsonschema.py SCHEMA INSTANCE\n")
        return 2
    _, schema_path, instance_path = argv
    try:
        with open(schema_path, encoding="utf-8") as handle:
            schema = json.load(handle)
        with open(instance_path, encoding="utf-8") as handle:
            instance = json.load(handle)
    except (OSError, ValueError) as error:
        sys.stderr.write("jsonschema: %s\n" % error)
        return 2

    out = []
    validate(instance, schema, "", out)

    identity = schema.get("$id")
    if identity is not None:
        printed = instance.get("schema") if isinstance(instance, dict) else None
        if str(printed) != str(identity):
            out.append(("schema", "the object says %r, this file's $id is %r: they are the same string" % (printed, identity)))

    for at, message in out:
        print("%s: %s" % (at or "(root)", message))
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
