"""Time-ordered evaluation. Future actuals never enter recursive model inputs."""
import math
import warnings
import numpy as np
import pandas as pd
from statsmodels.tsa.statespace.sarimax import SARIMAX
from statsmodels.tools.sm_exceptions import ConvergenceWarning

LAGS = (1, 2, 4, 8, 13, 52)


def validate_series(y):
    if y.empty or y.index.has_duplicates or not y.index.is_monotonic_increasing:
        raise ValueError('Weekly observations must be unique, nonempty and ordered')
    expected = pd.date_range(y.index[0], y.index[-1], freq='W-MON')
    if not y.index.equals(expected):
        raise ValueError('Expected a gap-free Monday-start weekly series')
    if not np.isfinite(y).all() or (y < 0).any():
        raise ValueError('Sales must be finite and nonnegative')


def metrics(actual, predicted, lower=None, upper=None):
    actual, predicted = np.asarray(actual, float), np.asarray(predicted, float)
    if actual.shape != predicted.shape or not len(actual):
        raise ValueError('Metric arrays must have the same nonzero length')
    error = predicted - actual
    denominator = np.abs(actual).sum()
    return {'MAE': float(np.abs(error).mean()), 'RMSE': float(np.sqrt(np.square(error).mean())),
            'WMAPE': float(np.abs(error).sum()/denominator) if denominator else None,
            'Bias': float(error.sum()/denominator) if denominator else None,
            'IntervalCoverage': float(np.mean((actual >= lower) & (actual <= upper))) if lower is not None else None,
            'N': len(actual)}


def rolling_origins(n, horizon, folds, holdout, min_train):
    end = n - holdout
    first = end - horizon * folds
    if first < min_train:
        raise ValueError(f'Need at least {min_train + horizon*folds + holdout} complete weeks; got {n}')
    return list(range(first, end, horizon))


def features(history, target_date):
    h = np.asarray(history, dtype=float)
    if len(h) < max(LAGS):
        raise ValueError('Lag features require 52 past observations')
    week = target_date.isocalendar().week
    return [h[-lag] for lag in LAGS] + [h[-w:].mean() for w in (4, 8, 13)] + [
        math.sin(2*math.pi*week/52.1775), math.cos(2*math.pi*week/52.1775), target_date.month]


def fit_model(name, y, season=52):
    values = np.asarray(y, float)
    if name in ('seasonal_naive', 'moving_average_4'):
        return {'name': name, 'season': season, 'history': values.tolist()}
    if name == 'sarima':
        with warnings.catch_warnings():
            warnings.simplefilter('error', ConvergenceWarning)
            result = SARIMAX(values, order=(1, 0, 0), seasonal_order=(0, 1, 0, season),
                             trend='c', enforce_stationarity=True, enforce_invertibility=True).fit(disp=False, maxiter=200)
        return {'name': name, 'result': result, 'n': len(y)}
    if name == 'xgboost':
        from xgboost import XGBRegressor
        x = np.array([features(values[:i], y.index[i]) for i in range(52, len(y))])
        model = XGBRegressor(n_estimators=200, max_depth=2, learning_rate=0.04,
                             min_child_weight=4, reg_lambda=10, subsample=1,
                             colsample_bytree=1, objective='reg:squarederror', random_state=42, n_jobs=1)
        model.fit(x, values[52:])
        return {'name': name, 'model': model}
    raise ValueError(name)


def predict_model(model, y, horizon):
    history = list(np.asarray(y, float))
    name = model['name']
    if name == 'sarima':
        result = model['result']
        if len(y) > model['n']:
            result = result.append(np.asarray(y.iloc[model['n']:]), refit=False)
        predicted = np.asarray(result.get_forecast(horizon).predicted_mean)
    elif name == 'seasonal_naive':
        if len(history) < model['season']:
            raise ValueError('Not enough seasonal history')
        predicted = np.array([history[-model['season'] + i % model['season']] for i in range(horizon)])
    elif name == 'moving_average_4':
        predicted = np.full(horizon, np.mean(history[-4:]))
    else:
        predicted = []
        for date in pd.date_range(y.index[-1] + pd.Timedelta(days=7), periods=horizon, freq='W-MON'):
            value = max(0., float(model['model'].predict(np.array([features(history, date)]))[0]))
            predicted.append(value)
            history.append(value)  # Append predictions, never validation/holdout actuals.
        predicted = np.asarray(predicted)
    if not np.isfinite(predicted).all():
        raise ValueError(f'{name} produced nonfinite forecasts')
    return np.maximum(predicted, 0)


def interval_scale(residuals, horizons, level):
    scaled = np.abs(np.asarray(residuals)) / np.sqrt(horizons)
    rank = min(len(scaled), math.ceil((len(scaled)+1)*level))
    if rank == 0:
        raise ValueError('Calibration residuals are required')
    return float(np.sort(scaled)[rank-1])


def prediction_bounds(predicted, scale):
    width = scale*np.sqrt(np.arange(1, len(predicted)+1))
    return np.maximum(0, predicted-width), predicted+width


def evaluate(y, config):
    validate_series(y)
    horizon = config['horizon']
    origins = rolling_origins(len(y), horizon, config['validation_folds'], config['holdout_weeks'], config['min_train_weeks'])
    candidates = ['seasonal_naive', 'moving_average_4', 'sarima']
    if config['include_xgboost']:
        candidates.append('xgboost')
    predictions, evaluations, failures, scales = [], [], {}, {}
    for name in candidates:
        rows = []
        try:
            for origin in origins:
                train, actual = y.iloc[:origin], y.iloc[origin:origin+horizon]
                model = fit_model(name, train, config['season_length'])
                predicted = predict_model(model, train, horizon)
                for i, (target, value) in enumerate(actual.items()):
                    rows.append(dict(ModelName=name, EvaluationSet='validation', OriginDate=train.index[-1],
                                     TargetDate=target, Horizon=i+1, Actual=float(value), Predicted=float(predicted[i]),
                                     LowerBound=None, UpperBound=None))
            a = np.array([r['Actual'] for r in rows])
            p = np.array([r['Predicted'] for r in rows])
            scales[name] = interval_scale(a-p, [r['Horizon'] for r in rows], config['interval_level'])
            evaluations.append(dict(ModelName=name, EvaluationSet='validation', **metrics(a, p)))
            predictions.extend(rows)
        except (ValueError, RuntimeError, ImportError, np.linalg.LinAlgError, ConvergenceWarning) as error:
            failures[name] = f'{type(error).__name__}: {error}'
    if not evaluations:
        raise RuntimeError(f'All candidates failed: {failures}')
    # Selection uses validation only. Holdout is opened after the champion is locked.
    champion = min(evaluations, key=lambda row: (row['WMAPE'] if row['WMAPE'] is not None else row['MAE'], row['RMSE']))['ModelName']
    train, holdout = y.iloc[:-config['holdout_weeks']], y.iloc[-config['holdout_weeks']:]
    model = fit_model(champion, train, config['season_length'])
    predicted = predict_model(model, train, len(holdout))
    lower, upper = prediction_bounds(predicted, scales[champion])
    evaluations.append(dict(ModelName=champion, EvaluationSet='holdout', **metrics(holdout, predicted, lower, upper)))
    for i, (target, value) in enumerate(holdout.items()):
        predictions.append(dict(ModelName=champion, EvaluationSet='holdout', OriginDate=train.index[-1],
                                TargetDate=target, Horizon=i+1, Actual=float(value), Predicted=float(predicted[i]),
                                LowerBound=float(lower[i]), UpperBound=float(upper[i])))
    model = fit_model(champion, y, config['season_length'])
    return dict(champion=champion, model=model, scale=scales[champion],
                evaluations=evaluations, predictions=predictions, failures=failures)
