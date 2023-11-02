# Why a(nother) Kafka rebalancer

I wrote this Kafka rebalancer because I was unhappy with the official one which comes with Kafka.

The official rebalancer creates a random layout resulting in unnecessary data reallocation over the Kafka Cluster.

This rebalancer instead tries to minimize the amount of partitions moved.


# Why in bash

Because Bash is widely available.
I had the necessity of running this tool on Linux nodes and on K8s pods (Concluent cp-helm-kafka chart). 
I therefore deployed this rebalancer using Bash commands available on both environments.


# When to run

The utility comes at handy under 2 different scenarios:

- When the number of brokers in the cluster changes (brokers are added or removed).     Use mode=manual and pass the (new) list of brokers

This is handy when for instance you plan to remove a broker and you want to first offload it from assigned partitions.
It is also useful when a new broker is added to the cluster and you want to redistribute existing partitions


- When a broker is not available and partitions need to be reassigned.      Use mode=auto

This is handy when one or more brokers are not available and you want to redistribute partitions. 

Some find it useful to run this utility periodically (or triggered by events) in an unattended way, to allow dynamic resizing of the cluster.


# How to run

Instructions can be found here:

bash kafka_smart_rebalancer.sh  --help


#  Can I contribute?

You are more than welcome to contribute. 
This tool does its job, but there is room for improvements. I have little time available and any contribution is highly apreciated!


# Sponsors

[Agileos Consulting LTD](https://www.agileosconsulting.com/)



