import hashlib
import json
import pickle
from pathlib import Path
import numpy as np
import pandas as pd
from .config import ROOT
from .database import connect, read_weekly, frame
from .forecasting import evaluate, validate_series, predict_model, prediction_bounds


def fingerprint(y):
    return hashlib.sha256(y.to_csv(float_format='%.6f').encode()).hexdigest()


def code_version(config):
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    for path in sorted((ROOT/'src/companyx').glob('*.py')):
        digest.update(path.read_bytes())
    return digest.hexdigest()[:20]


def publish(config, y, batch, result, run_type, artifact_path, data_hash, version):
    future_dates = pd.date_range(y.index[-1]+pd.Timedelta(days=7), periods=config['horizon'], freq='W-MON')
    predicted = predict_model(result['model'], y, config['horizon'])
    lower, upper = prediction_bounds(predicted, result['scale'])
    with connect(config) as conn:
        conn.execute('SET XACT_ABORT ON')
        lock = conn.execute("DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource='CompanyX_Forecast',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000; SELECT @r;").fetchval()
        if lock < 0:
            raise RuntimeError('Could not acquire forecast publishing lock')
        existing = conn.execute('SELECT ForecastRunKey FROM dw.ForecastRun WHERE DataHash=? AND CodeVersion=? AND RunType=?',
                                data_hash, version, run_type).fetchval()
        if existing:
            conn.commit()
            return int(existing), True
        # Add only future Mondays not already in the date dimension (normally populated by ETL).
        for date in future_dates:
            if not conn.execute('SELECT 1 FROM dw.DimDate WHERE DateKey=?', int(date.strftime('%Y%m%d'))).fetchval():
                raise RuntimeError('DimDate does not cover forecast horizon; extend calendar through ETL')
        key = conn.execute('''INSERT dw.ForecastRun(TrainingEndDate,SourceBatchID,DataHash,CodeVersion,Champion,
            ModelPath,RunType,ConfigJson,IntervalLevel) OUTPUT INSERTED.ForecastRunKey VALUES(?,?,?,?,?,?,?,?,?)''',
            y.index[-1].date(), batch, data_hash, version, result['champion'],
            str(artifact_path.relative_to(ROOT)), run_type, json.dumps(config, sort_keys=True), config['interval_level']).fetchval()
        conn.execute('UPDATE dw.ForecastRun SET TrainingRunKey=?,ForecastOriginDate=?,TrainingEndDate=? WHERE ForecastRunKey=?',
                     key if run_type=='train' else result['training_run_key'], y.index[-1].date(),
                     result['training_series'].index[-1].date(), key)
        conn.cursor().executemany('INSERT dw.FactSalesForecast VALUES(?,?,?,?,?,?)', [
            (key, int(d.strftime('%Y%m%d')), i+1, float(predicted[i]), float(lower[i]), float(upper[i]))
            for i, d in enumerate(future_dates)])
        if run_type == 'train':
            conn.cursor().executemany('''INSERT dw.ModelEvaluation(ForecastRunKey,ModelName,EvaluationSet,MAE,RMSE,WMAPE,Bias,IntervalCoverage,N)
                VALUES(?,?,?,?,?,?,?,?,?)''', [(key, r['ModelName'], r['EvaluationSet'], r['MAE'], r['RMSE'],
                                               r['WMAPE'], r['Bias'], r['IntervalCoverage'], r['N']) for r in result['evaluations']])
            conn.cursor().executemany('INSERT dw.BacktestPrediction VALUES(?,?,?,?,?,?,?,?,?,?)', [
                (key,r['ModelName'],r['EvaluationSet'],r['OriginDate'].date(),r['TargetDate'].date(),r['Horizon'],
                 r['Actual'],r['Predicted'],r['LowerBound'],r['UpperBound']) for r in result['predictions']])
        conn.commit()
    return int(key), False


def forecast(config, mode='train'):
    y, batch = read_weekly(config)
    validate_series(y)
    data_hash, version = fingerprint(y), code_version(config)
    model_dir = ROOT/'artifacts/models'
    model_dir.mkdir(parents=True, exist_ok=True)
    pointer = model_dir/'latest.json'
    if mode == 'train':
        result = evaluate(y, config)
        result.update(training_series=y, version=version, data_hash=data_hash)
        artifact = model_dir/f'{data_hash[:16]}_{version}.pkl'
        # Only load locally generated artifacts. Pickle is never accepted as user input.
        temp = artifact.with_suffix('.tmp')
        temp.write_bytes(pickle.dumps(result))
        temp.replace(artifact)
    else:
        if not pointer.exists():
            raise ValueError('Run train before daily scoring')
        artifact = (ROOT/json.loads(pointer.read_text())['artifact']).resolve()
        if not artifact.is_relative_to(model_dir.resolve()):
            raise ValueError('Invalid model artifact path')
        result = pickle.loads(artifact.read_bytes())
        past = result['training_series']
        if result['version'] != version or len(y)<len(past) or not y.iloc[:len(past)].equals(past):
            raise ValueError('Code/config or historical sales changed; retrain before scoring')
    key, reused = publish(config, y, batch, result, mode, artifact, data_hash, version)
    if mode == 'train':
        result['training_run_key'] = key
        artifact.write_bytes(pickle.dumps(result))
        pointer.write_text(json.dumps({'artifact': str(artifact.relative_to(ROOT))}), encoding='utf-8')
    report = dict(run_key=key, reused=reused, mode=mode, champion=result['champion'],
                  complete_weeks=len(y), training_end=str(y.index[-1].date()), data_hash=data_hash,
                  horizon=config['horizon'], evaluations=result['evaluations'], failures=result['failures'],
                  release_status='REVIEW_REQUIRED' if any(r['EvaluationSet']=='holdout' and (r['WMAPE'] is None or r['WMAPE']>0.30) for r in result['evaluations']) else 'PLANNING_REVIEW',
                  interval_note=f"Approximate {config['interval_level']:.0%} bands calibrated on rolling validation errors; holdout coverage reported separately.")
    (ROOT/'artifacts/forecast_report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    return report


def profile(config):
    source = config['source_database']
    queries = {
        'source': f'''SELECT MIN(OrderDate) FirstOrder,MAX(OrderDate) LastOrder,COUNT(*) Orders FROM [{source}].Sales.SalesOrderHeader''',
        'order_status': f'SELECT Status,COUNT(*) Orders FROM [{source}].Sales.SalesOrderHeader GROUP BY Status',
        'source_shipped_valid': f'''SELECT COUNT(*) Lines,COUNT(DISTINCT h.SalesOrderID) Orders,SUM(d.LineTotal) NetSales
            FROM [{source}].Sales.SalesOrderHeader h JOIN [{source}].Sales.SalesOrderDetail d ON d.SalesOrderID=h.SalesOrderID
            WHERE h.Status=5 AND d.OrderQty>0 AND d.UnitPrice>=0 AND d.UnitPriceDiscount BETWEEN 0 AND 1''',
        'quarantine': 'SELECT Reason,COUNT(*) Lines FROM ctl.RejectedSales GROUP BY Reason',
        'warehouse': '''SELECT COUNT(*) Lines,COUNT(DISTINCT SalesOrderID) Orders,SUM(NetSales) NetSales,
            SUM(CASE WHEN EstimatedCost IS NULL THEN 1 ELSE 0 END) MissingCostLines FROM mart.Sales''',
        'weekly': 'SELECT IsComplete,COUNT(*) Weeks,MIN(WeekStart) FirstWeek,MAX(WeekStart) LastWeek FROM mart.WeeklySales GROUP BY IsComplete',
        'batches': 'SELECT TOP(8) * FROM ctl.Batch ORDER BY BatchID DESC',
    }
    with connect(config) as conn:
        report = {name: frame(conn, query).to_dict(orient='records') for name, query in queries.items()}
    path = ROOT/'artifacts/data_profile.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(report, indent=2, default=str), encoding='utf-8')
    return report
