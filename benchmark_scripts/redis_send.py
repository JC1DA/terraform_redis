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
parser.add_argument("--num_iters", type=int, default=1000)
parser.add_argument("--pkg_size_bytes", type=int, default=100 * 1000)
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
        return client
    else:
        # Azure Redis Cache
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

    for _ in range(args.num_iters):
        pkg = pkgs[np.random.randint(len(pkgs))]
        client.rpush(args.topic, pkg)


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
    for _ in range(1000):
        pkg = np.random.randint(0, 255, size=(args.pkg_size_bytes,)).astype(np.uint8)
        pkg = pickle.dumps(pkg)
        pkgs.append(pkg)

    t0 = time.time()
    benchmark(args, pkgs)
    lat = time.time() - t0
    fps = args.num_processes * args.num_iters / lat
    print(f"send_fps: {fps}")
