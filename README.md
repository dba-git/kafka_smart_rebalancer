# Why a(nother) Kafka rebalancer

I wrote this Kafka rebalancer because I was unhappy with the official one which comes with Kafka.

The official rebalancer creates a random layout resulting in unnecessary data reallocation over the Kafka Cluster.

This rebalancer instead tries to minimize the amount of partitions moved.

You can find a more detailed explanation more down in this page

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

# Benchmark - A more details explanation

Kafka topics are divided in one or more partitions divided between the cluster brokers.

Also each topic comes with a 'replication factor', that is: over how many brokers is a partition available.


This is how the 'canary' topic is distributed over 5 brokers in our lab.
The topic has 20 partitions of ~100GB each
 

	Topic: canary	Partition: 0	 Replicas: 1,4,2	
	Topic: canary	Partition: 1	 Replicas: 4,2,3	
	Topic: canary	Partition: 2	 Replicas: 2,3,0	
	Topic: canary	Partition: 3	 Replicas: 3,0,1	
	Topic: canary	Partition: 4	 Replicas: 0,1,4	
	Topic: canary	Partition: 5	 Replicas: 1,2,3	
	Topic: canary	Partition: 6	 Replicas: 4,3,0	
	Topic: canary	Partition: 7	 Replicas: 2,0,1	
	Topic: canary	Partition: 8	 Replicas: 3,1,4	
	Topic: canary	Partition: 9	 Replicas: 0,4,2	
	Topic: canary	Partition: 10	 Replicas: 1,3,0	
	Topic: canary	Partition: 11	 Replicas: 4,0,1	
	Topic: canary	Partition: 12	 Replicas: 2,1,4	
	Topic: canary	Partition: 13	 Replicas: 3,4,2	
	Topic: canary	Partition: 14	 Replicas: 0,2,3	
	Topic: canary	Partition: 15	 Replicas: 1,0,4	
	Topic: canary	Partition: 16	 Replicas: 4,1,2	
	Topic: canary	Partition: 17	 Replicas: 2,4,3	
	Topic: canary	Partition: 18	 Replicas: 3,2,0	
	Topic: canary	Partition: 19	 Replicas: 0,3,1	


When one broker is added, this was the layout proposed by the official kafka tool 'kafka-reassign-partitions'

                                            former        new     # partitions moved
    Topic: canary	Partition: 0	 Replicas: 1,4,2   -> 4,5,0   2
    Topic: canary	Partition: 1	 Replicas: 4,2,3   -> 5,0,1   3
    Topic: canary	Partition: 2	 Replicas: 2,3,0   -> 0,1,2   1
    Topic: canary	Partition: 3	 Replicas: 3,0,1   -> 1,2,3   1
    Topic: canary	Partition: 4	 Replicas: 0,1,4   -> 2,3,4   2
    Topic: canary	Partition: 5	 Replicas: 1,2,3   -> 3,4,5   2
    Topic: canary	Partition: 6	 Replicas: 4,3,0   -> 4,0,1   1
    Topic: canary	Partition: 7	 Replicas: 2,0,1   -> 5,1,2   1
    Topic: canary	Partition: 8	 Replicas: 3,1,4   -> 0,2,3   2
    Topic: canary	Partition: 9	 Replicas: 0,4,2   -> 1,3,4   2
    Topic: canary	Partition: 10	 Replicas: 1,3,0   -> 2,4,5   3
    Topic: canary	Partition: 11	 Replicas: 4,0,1   -> 3,5,0   2
    Topic: canary	Partition: 12	 Replicas: 2,1,4   -> 4,1,2   0
    Topic: canary	Partition: 13	 Replicas: 3,4,2   -> 5,2,3   1
    Topic: canary	Partition: 14	 Replicas: 0,2,3   -> 0,3,4   1
    Topic: canary	Partition: 15	 Replicas: 1,0,4   -> 1,4,5   1
    Topic: canary	Partition: 16	 Replicas: 4,1,2   -> 2,5,0   3
    Topic: canary	Partition: 17	 Replicas: 2,4,3   -> 3,0,1   2
    Topic: canary	Partition: 18	 Replicas: 3,2,0   -> 4,2,3   1
    Topic: canary	Partition: 19	 Replicas: 0,3,1   -> 5,3,4   2

    
Total partitions moved = 33 
Total data moved around the cluster = 3.3 TB


With Kafka Smart Rebalancer:

                                               former     new         # partitions moved
    Topic: canary	Partition: 0	 Replicas: 1,4,2  ->  1,5,2	  1
    Topic: canary	Partition: 1	 Replicas: 4,2,3  ->  4,2,5	  1
    Topic: canary	Partition: 2	 Replicas: 2,3,0  ->  2,3,5	  1
    Topic: canary	Partition: 3	 Replicas: 3,0,1  ->  3,0,5	  1
    Topic: canary	Partition: 4	 Replicas: 0,1,4  ->  0,5,4	  1
    Topic: canary	Partition: 5	 Replicas: 1,2,3  ->  5,2,3	  1
    Topic: canary	Partition: 6	 Replicas: 4,3,0  ->  5,3,0	  1
    Topic: canary	Partition: 7	 Replicas: 2,0,1  ->  2,5,1	  1
    Topic: canary	Partition: 8	 Replicas: 3,1,4  ->  3,1,5	  1
    Topic: canary	Partition: 9	 Replicas: 0,4,2  ->  5,4,2	  1
    Topic: canary	Partition: 10	 Replicas: 1,3,0  ->  1,3,0	  0
    Topic: canary	Partition: 11	 Replicas: 4,0,1  ->  4,0,1	  0
    Topic: canary	Partition: 12	 Replicas: 2,1,4  ->  2,1,4	  0
    Topic: canary	Partition: 13	 Replicas: 3,4,2  ->  3,4,2	  0
    Topic: canary	Partition: 14	 Replicas: 0,2,3  ->  0,2,3	  0
    Topic: canary	Partition: 15	 Replicas: 1,0,4  ->  1,0,4	  0
    Topic: canary	Partition: 16	 Replicas: 4,1,2  ->  4,1,2	  0
    Topic: canary	Partition: 17	 Replicas: 2,4,3  ->  2,4,3	  0
    Topic: canary	Partition: 18	 Replicas: 3,2,0  ->  3,2,0	  0
    Topic: canary	Partition: 19	 Replicas: 0,3,1  ->  0,3,1	  0
     
Total partitions moved = 10
Total data moved around the cluster = 1.0 TB


For the nerds...

Moved partitions in the old way: 

     (1-(RF/B)) * (P*RF)




Moved partitions using Kafka Smart Rebalancer (one broker increment):

    ((P*RF) / B ) * (BA)


RF = Replication Factor
P  = Partitions
B  = Brokers 
BA = Number of brokers added to the cluster



![Old VS NEW](https://github.com/dba-git/kafka_smart_rebalancer/blob/main/pics/moved_partitions.png)




# Sponsors

[Agileos Consulting LTD](https://www.agileosconsulting.com/)



