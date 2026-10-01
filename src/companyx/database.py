from contextlib import contextmanager
import pandas as pd
import pyodbc
from .config import connection_string


@contextmanager
def connect(config, database=None, autocommit=False):
    conn = pyodbc.connect(connection_string(config, database), timeout=15, autocommit=autocommit)
    try:
        yield conn
    finally:
        conn.close()


def frame(conn, sql, params=()):
    cursor = conn.cursor().execute(sql, params)
    return pd.DataFrame.from_records([tuple(row) for row in cursor.fetchall()],
                                     columns=[col[0] for col in cursor.description])


def run_etl(config, full=False):
    with connect(config, autocommit=True) as conn:
        cursor = conn.cursor().execute('EXEC ctl.LoadSales @FullReconcile=?,@LookbackDays=?',
                                      int(full), config['lookback_days'])
        while cursor.description is None:
            if not cursor.nextset():
                raise RuntimeError('ETL did not return an audit row')
        result = dict(zip([d[0] for d in cursor.description], cursor.fetchone()))
        if result['Status'] != 'SUCCESS':
            raise RuntimeError(str(result))
        return result


def read_weekly(config):
    # Serializable transaction ties the data fingerprint to one committed ETL batch.
    with connect(config) as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE')
        batch = conn.execute("SELECT MAX(BatchID) FROM ctl.Batch WHERE Status='SUCCESS'").fetchval()
        data = frame(conn, 'SELECT WeekStart,NetSales FROM mart.WeeklySales WHERE IsComplete=1 ORDER BY WeekStart')
        conn.commit()
    if not batch or data.empty:
        raise ValueError('No successful ETL / complete sales weeks. Run etl first.')
    data['WeekStart'] = pd.to_datetime(data['WeekStart'])
    return data.set_index('WeekStart')['NetSales'].astype(float), int(batch)
