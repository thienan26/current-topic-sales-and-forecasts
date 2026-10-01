import json
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_config(path=None):
    path = Path(path) if path else ROOT / 'config.example.json'
    config = json.loads(path.read_text(encoding='utf-8-sig'))
    for key in ('source_database', 'warehouse_database'):
        if not re.fullmatch(r'CompanyX_BI_[A-Za-z0-9_]+', config[key]):
            raise ValueError(f'{key} must name a dedicated CompanyX_BI_ database')
    if config['source_database'] == config['warehouse_database']:
        raise ValueError('Source and warehouse must differ')
    if not 0 < config['interval_level'] < 1:
        raise ValueError('interval_level must be between 0 and 1')
    if not 1 <= config['horizon'] <= config['season_length']:
        raise ValueError('horizon must be between 1 and season_length')
    if config['holdout_weeks'] != config['horizon']:
        raise ValueError('This implementation requires holdout_weeks == horizon')
    if config['validation_folds'] < 2 or config['min_train_weeks'] < 2 * config['season_length']:
        raise ValueError('Use at least two folds and two seasons of initial training')
    return config


def connection_string(config, database=None):
    def escaped(value):
        return '{' + str(value).replace('}', '}}') + '}'
    fields = {'DRIVER': config['odbc_driver'], 'SERVER': config['server'],
              'DATABASE': database or config['warehouse_database'],
              'Encrypt': 'yes' if config['encrypt'] else 'no',
              'TrustServerCertificate': 'yes' if config['trust_server_certificate'] else 'no'}
    if config['trusted_connection']:
        fields['Trusted_Connection'] = 'yes'
    else:
        fields.update(UID=os.environ['COMPANYX_SQL_USER'], PWD=os.environ['COMPANYX_SQL_PASSWORD'])
    return ';'.join(f'{k}={escaped(v)}' for k, v in fields.items())
