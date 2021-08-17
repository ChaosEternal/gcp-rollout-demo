#!/usr/bin/env python3
import argparse
import os
import pprint
import time
import uuid
import sys
import argparse

from google.api import label_pb2 as ga_label
from google.api import metric_pb2 as ga_metric
from google.cloud import monitoring_v3

import google.auth

PROJECT_ID = os.environ["TARGET_PROJECT"]
THRESHOLD = float(os.environ["THRESHOLD"])

def tryconnect(cls):
    for _i in [1, 2, 4, 8, 16]:
        try:
#            queryclient = monitoring_v3.QueryServiceClient()
            queryclient = cls()
            break
        except google.auth.exceptions.DefaultCredentialsError as e:
            connecterror = e
            time.sleep(_i * 0.1)
            continue
    else:
        raise(e)
    return queryclient

def run_mql_check_threshold(project_id):
    """
    check slo by run a MQL query,
    the result of the query should be group by response_code and aggregated on request count
    if count of error requests/count of total request > threshold,
    this check fails.
    Gets query from env MQL_QUERY, the query should use align delta
    example:
        fetch k8s_pod
        | metric 'istio.io/service/client/request_count'
        | filter
          (resource.cluster_name == 'democd'
           && resource.pod_name =~ 'istio-ingressgateway-.*')
          && (metric.destination_service_name == 'rollouts-demo-canary')
        | align delta(5m)
        | every 5m
        | group_by [metric.response_code],
          [value_request_count_aggregate: aggregate(value.request_count)]
    """
    queryclient = tryconnect(monitoring_v3.QueryServiceClient)
    project_name = f"projects/{project_id}"

    QUERY = os.environ["MQL_QUERY"]

    qreq = monitoring_v3.QueryTimeSeriesRequest(name=project_name,
                                                query=QUERY)
    results = queryclient.query_time_series(qreq)
    distribution = [(x.label_values[0].int64_value,
                     x.point_data[0].values[0].int64_value)
                    for x in results]
    error_count = 0
    total_count = 0
    for code, count in distribution:
        if code > 399:
            error_count += count
        total_count += count
    print(results, file=sys.stderr)
    print("0xC0DE metrics:", error_count, total_count, file=sys.stderr)
    if error_count*1.0/(total_count+0.1) > THRESHOLD:
        raise Exception("Error budget drops too fast")
    return 0

def check_defined_slo(project_id):
    """
    check slo burn rate is less than THRESHOLD
    slo is read from env: DEFINEDSLO
    example:
    projects/[project_id]/services/[service_id]/serviceLevelObjectives/[sloid]

    if no data, this check also fails.
    """
    queryclient = tryconnect(monitoring_v3.MetricServiceClient)
    project_name = f"projects/{project_id}"
    now = time.time()
    seconds = int(now)
    nanos = int((now - seconds) * 10 ** 9)
    interval = monitoring_v3.TimeInterval(
        {
            "end_time": {"seconds": seconds, "nanos": nanos},
            "start_time": {"seconds": (seconds - 300), "nanos": nanos},
        }
    )
    gcpslo = os.environ["DEFINEDSLO"]
    results = queryclient.list_time_series(
        request={
            "name": project_name,
            "filter": f'select_slo_burn_rate("{gcpslo}", "300s")',
            "interval": interval,
        }
    )
    print(results, sys.stderr)
    burnrate = [[y.value.double_value for y in x.points] for x in results][0][0]
    print("0xC0DE slo burn rate", burnrate, file=sys.stderr)
    if burnrate > THRESHOLD:
        raise Exception("Error budget drops too fast")
    return 0

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Demo app for rollouts.')
    parser.add_argument('-r', '--run', dest='run',
                        type=str, default="check_defined_slo",
                        help="the check to run, default is check_defined_slo")
    cfg = parser.parse_args()
    if cfg.run == "check_defined_slo":
        sys.exit(check_defined_slo(PROJECT_ID))
    else:
        sys.exit(run_mql_check_threshold(PROJECT_ID))
