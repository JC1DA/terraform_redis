import argparse
import pickle
import time
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import Manager
from multiprocessing.dummy import Process
from typing import List

import numpy as np
import requests

parser = argparse.ArgumentParser(description="Benchmarker")
parser.add_argument(
    "--redis_address", type=str, default="redis-standalone.ot-operators"
)
parser.add_argument("--redis_port", type=int, default=6379)
parser.add_argument("--redis_password", type=str, default="")
parser.add_argument("--num_processes", type=int, default=1)
parser.add_argument("--topic", type=str, default="test")
parser.add_argument("--num_items", type=int, default=1000)
args = parser.parse_args()


def init_redis_client(address: str, port: int, password: str, is_using_ssl=False):
    if not is_using_ssl:
        client = None
        try:
            from rediscluster import RedisCluster

            redis_startup_nodes = [{"host": f"{address}", "port": f"{port}"}]
            client = RedisCluster(
                startup_nodes=redis_startup_nodes,
                decode_responses=False,
                password=password,
            )
        except:
            import redis

            client = redis.StrictRedis(
                host=f"{address}",
                port=port,
                password=password,
                ssl=is_using_ssl,
                ssl_cert_reqs="none",
                socket_timeout=10,
                socket_connect_timeout=10,
            )

        # try to ping
        # while True:
        #     try:
        #         client.ping()
        #         break
        #     except:
        #         print("Redis server is not available ...")
        #         time.sleep(1)

        return client
    else:
        import redis

        return redis.StrictRedis(
            host=f"{address}",
            port=port,
            password=password,
            ssl=is_using_ssl,
            ssl_cert_reqs="none",
            socket_timeout=10,
            socket_connect_timeout=10,
        )

    return None


def benchmark_process(args, pkgs):
    client = init_redis_client(
        args.redis_address, args.redis_port, args.redis_password, False
    )

    count = 0
    while count < args.num_items:
        data = client.blpop([args.topic], timeout=0.1)
        if data is None:
            time.sleep(0.001)
            continue

        _, d = data
        count += 1


def benchmark(args, pkgs):
    processes: List[Process] = []

    for _ in range(args.num_processes):
        p = Process(target=benchmark_process, args=(args, pkgs))
        processes.append(p)

    for p in processes:
        p.start()

    for p in processes:
        p.join()


if __name__ == "__main__":
    pkgs = []
    t0 = time.time()
    benchmark(args, pkgs)
    lat = time.time() - t0
    fps = args.num_processes * args.num_items / lat
    print(f"recv_fps: {fps}")
