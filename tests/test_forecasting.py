import numpy as np
import pandas as pd
import pytest
from companyx.forecasting import (
    features, metrics, rolling_origins, validate_series, fit_model,
    predict_model, interval_scale, prediction_bounds,
)


def weekly(n=160):
    return pd.Series(np.arange(n, dtype=float)+100, index=pd.date_range('2020-01-06', periods=n, freq='W-MON'))


def test_splits_never_touch_holdout_and_match_eight_week_horizon():
    origins = rolling_origins(160, 8, 4, 8, 104)
    assert origins == [120, 128, 136, 144]
    assert all(o+8<=152 for o in origins)
    with pytest.raises(ValueError):
        rolling_origins(100, 8, 4, 8, 104)


def test_calendar_gaps_and_nonmonday_dates_rejected():
    validate_series(weekly())
    with pytest.raises(ValueError):
        validate_series(weekly().drop(weekly().index[10]))
    shifted = weekly()
    shifted.index += pd.Timedelta(days=1)
    with pytest.raises(ValueError):
        validate_series(shifted)


def test_features_use_only_history_before_target():
    y = weekly()
    x = features(y.iloc[:100], y.index[100])
    assert x[:6] == [199,198,196,192,187,148]
    assert x[6] == np.mean([196,197,198,199])


def test_recursive_forecast_uses_predictions_for_later_horizons():
    class LastLagPlusOne:
        def predict(self, x):
            return np.array([x[0,0]+1])
    model = {'name':'xgboost','model':LastLagPlusOne()}
    np.testing.assert_allclose(predict_model(model, weekly(100), 3), [200,201,202])


def test_baselines_and_bias_sign():
    y = weekly()
    pred = predict_model(fit_model('seasonal_naive', y), y, 8)
    np.testing.assert_equal(pred, y.iloc[-52:-44])
    assert metrics([100,100],[110,110])['Bias'] == pytest.approx(0.1)
    assert metrics([0,0],[1,1])['WMAPE'] is None


def test_intervals_are_ordered_nonnegative_and_include_point():
    scale = interval_scale([10,-20,30,-40],[1,2,3,4],0.8)
    p = np.array([1.,100.,200.])
    lower, upper = prediction_bounds(p, scale)
    assert (lower>=0).all() and (lower<=p).all() and (upper>=p).all()
    assert (upper-p)[2] > (upper-p)[0]
