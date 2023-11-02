# Why a(nother) Kafka rebalancer

I wrote this Kafka rebalancer because I was unhappy with the official one which comes with Kafka.

The official rebalancer creates a random layout resulting in unnecessary data reallocation over the Kafka cluster.

This rebalancer instead tries to minimize the amount of partitions moved.


# Why in bash

Because bash is widely available.
I had the necessity of running this task on Linux nodes and on K8s deployement (Concluent cp-helm-kafka chart). 
I therefore deployed this rebalancer using bash commands available on both environments.


# When to run

The utility comes at handy under 2 different scenarios:

- When a new broker is added and partitions need to be reassigned.     Use mode=manual
- When a broker is not available and partitions need to be reassigned. Use mode=auto

# How to run

Instructions can be found here:

bash kafka_smart_rebalancer.sh  --help


#  Can I contribute?

You are more than welcome to contribute. 
This tool does its job, but there is room for improvements. I have little time available and any contribution is highly apreciated!




