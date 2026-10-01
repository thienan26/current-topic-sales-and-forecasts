import argparse
import json
from .config import load_config
from .database import run_etl
from .pipeline import forecast, profile


def main():
    parser = argparse.ArgumentParser(description='CompanyX SQL warehouse and weekly forecasting')
    parser.add_argument('--config', help='JSON configuration path')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('etl').add_argument('--full', action='store_true', help='Full data reconciliation')
    sub.add_parser('train', help='Rolling validation, untouched holdout, refit and publish')
    sub.add_parser('score', help='Daily forecast with frozen champion parameters')
    sub.add_parser('profile', help='Write source and warehouse reconciliation evidence')
    args = parser.parse_args()
    config = load_config(args.config)
    if args.command == 'etl':
        result = run_etl(config, args.full)
    elif args.command == 'profile':
        result = profile(config)
    else:
        result = forecast(config, args.command)
    print(json.dumps(result, indent=2, default=str))


if __name__ == '__main__':
    main()
