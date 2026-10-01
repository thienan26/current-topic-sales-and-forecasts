"""Validate PBIR documents against Microsoft's published JSON schemas (cached locally)."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen
from referencing import Registry, Resource
from jsonschema import Draft7Validator

root=Path(__file__).resolve().parents[1]
cache=root/'artifacts/schemas'
cache.mkdir(parents=True,exist_ok=True)


def retrieve(uri):
    path=cache/(hashlib.sha256(uri.encode()).hexdigest()+'.json')
    if not path.exists():
        if not uri.startswith('https://developer.microsoft.com/json-schemas/'):
            raise ValueError('Unexpected schema host: '+uri)
        raw=uri.replace('https://developer.microsoft.com/json-schemas/','https://raw.githubusercontent.com/microsoft/json-schemas/main/')
        with urlopen(raw,timeout=30) as response:
            path.write_bytes(response.read())
    return Resource.from_contents(json.loads(path.read_text(encoding='utf-8-sig')))


registry=Registry(retrieve=retrieve)
checked=0
for path in (root/'powerbi').rglob('*'):
    if path.suffix not in ('.json','.pbir','.pbism') or '.pbi' in path.parts:
        continue
    data=json.loads(path.read_text(encoding='utf-8'))
    if '$schema' not in data:
        continue
    schema=retrieve(data['$schema']).contents
    errors=list(Draft7Validator(schema,registry=registry).iter_errors(data))
    if errors:
        raise ValueError(f'{path.relative_to(root)}: '+ '\n'.join(str(e) for e in errors))
    checked+=1
print(f'Validated {checked} PBIR / semantic-model metadata documents against official schemas.')
(root/'artifacts/powerbi_validation.json').write_text(json.dumps({'schema_documents_validated':checked,'rendered_in_desktop':False},indent=2),encoding='utf-8')
