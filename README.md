# kubernetes-velociraptor
This guide is for setting up Velociraptor in Kubernetes (AWS)

Velociraptor is a tool for collecting host based state information using Velocidex Query Language (VQL) queries.

You can understand more from the links below:

* https://github.com/Velocidex/velociraptor
* https://www.velocidex.com/docs/

Requirements:
* [Amazon EFS](https://aws.amazon.com/efs/) (persistent storage)
* [Kubernetes cluster](https://kubernetes.io/)

We will not be covering setting up the kubernetes cluster and the EFS in this tutorial. 

AWS provided a guide [here](https://aws.amazon.com/premiumsupport/knowledge-center/eks-pods-efs/) for setting up the EFS in Kubernetes.

As you might know, Velociraptor installation is very simple as it packs everything into one single binary for both server and/or client agent without needing any external dependencies like MySQL, libraries, etc.

Everything is inside one single binary that you need to generate the config, run the server side or client side.

This means that we will need to pack the binary into the docker image before moving on the Kubernetes part.

You can download the latest version of Velociraptor from [here](https://github.com/Velocidex/velociraptor/releases) and then place them in the directory as your dockerfile, a sample shared below - Feel free to customise it.

```
FROM ubuntu:19.04

COPY ./velociraptor-v0.3.6-linux-amd64 /home/ubuntu/velociraptor
 
WORKDIR /home/ubuntu/
 
RUN chmod +x ./velociraptor
 
CMD ["/home/ubuntu/velociraptor", "--config", "/home/ubuntu/server.config.yaml", "frontend", "-v"]
```

Next, we will build this image and then push them to your AWS ECR repo.

```
docker build -t velociraptor .

docker tag velociraptor:latest XXXX.XXX.ecr.ap-southeast-1.amazonaws.com/repoName:velociraptor

docker push XXXX.XXX.ecr.ap-southeast-1.amazonaws.com/repoName:velociraptor
```

Once done, we will move on to the Kubernetes part.

If you have noticed in the above dockerfile, we are pointing the Velociraptor config file to `/home/ubuntu/server.config.yaml` - this means we will have to generate the config first and then mount that config to that path.

We will now need to generate the config file for Velociraptor server and clients.

Using the same binary that you packed into the docker image, you can run this command to generate your config files. Refer to Velocidex [docs](https://www.velocidex.com/docs/getting-started/stand_alone/) if needed.

```
$ velociraptor config generate -i
?
Welcome to the Velociraptor configuration generator
---------------------------------------------------
 
I will be creating a new deployment configuration for you. I will
begin by identifying what type of deployment you need.
 
  [Use arrows to move, space to select, type to filter]
  > Self Signed SSL
    Automatically provision certificates with Lets Encrypt
    Authenticate users with Google OAuth SSO

 Self Signed SSL
 Generating keys please wait....
 ? Enter the frontend port to listen on. 8000
 ? What is the public DNS name of the Frontend (e.g. www.example.com): velociraptor.example.com
 ? Path to the datastore directory. /home/ubuntu/velo-datastore
 ? Path to the logs directory. /home/ubuntu/velo-logs
 ? Where should i write the server config file? server.config.yaml
 ? Where should i write the client config file? client.config.yaml
 ? GUI Username or email address to authorize (empty to end): mic
 ? Password ********* 
```

After you have generated the config file, you will now have both server.config.yaml and client.config.yaml files. For now we just require the `server.config.yaml` file.

Remember that above, our dockerfile points to `/home/ubuntu/server.config.yaml` - we need to store the config file into configmap and mount it to that path.

The below commands shows how to get the JSON output file for creating configmap and then make necessary changes as you like before applying to the cluster.
```
$ kubectl create configmap serverconfig --from-file=server.config.yaml --dry-run -o yaml > configmap-server.yaml

$ kubectl apply -f configmap-server.yaml
configmap/serverconfig created
```

Next, we need to create our deployment and service to Kubernetes. You can use the below sample deployment file:
```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: velociraptor
  namespace: velociraptor
  labels:
    app: velociraptor
spec:
  replicas: 2
  selector:
    matchLabels:
      app: velociraptor
  template:
    metadata:
      labels:
        app: velociraptor
    spec:
      containers:
      - name: velociraptor
        image: XXXX.XXX.ecr.ap-southeast-1.amazonaws.com/repoName:velociraptor
        imagePullPolicy: Always
        ports:
          - containerPort: 8889
          - containerPort: 8000
        volumeMounts:
          - name: efs-datastore
            mountPath: "/home/ubuntu/velo-datastore"
          - name: efs-logs
            mountPath: "/home/ubuntu/velo-logs"
          - name: server-config
            mountPath: "/home/ubuntu/server.config.yaml"
            subPath: server.config.yaml
      volumes:
        - name: efs-datastore
          persistentVolumeClaim:
            claimName: efs
        - name: efs-logs
          persistentVolumeClaim:
            claimName: efs2
        - name: server-config
          configMap:
            name: serverconfig
            items:
            - key: server.config.yaml
              path: server.config.yaml
---
kind: Service
apiVersion: v1
metadata:
  name: velociraptor
  namespace: velociraptor
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: 0.0.0.0/0
    service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: "environment=dev"
spec:
  type: LoadBalancer
  selector:
    app: velociraptor
  ports:
    - name: gui
      protocol: TCP
      port: 8889
      targetPort: 8889
    - name: frontend
      protocol: TCP
      port: 8000
      targetPort: 8000
```

Some explanation around the above deployment config:

1. We uses a replicas of 2 (2 pods running)
   - Take note, Velociraptor doesn't handle multiple frontends for now - you might realise if you issue a command to one host - it might take some time if that host is connected to another frontend.
2. We have used the image that we built just now with the dockerfile and pushed to the ECR.
3. We exposed the port on 8000 (frontend) and 8889 (GUI)
4. We then mount total of 3 paths, one for the datastore, one for the logs (both using EFS) and then lastly the configmap that store the server configs.
5. For the service side, we used an internal load balancer and exposed those ports.

After creating the above, you should see the output like these:
```
pod/velociraptor-6db4b5ff8d-rt2nf      1/1     Running   0          20m
pod/velociraptor-6db4b5ff8d-twflz      1/1     Running   0          20m
service/velociraptor        LoadBalancer   172.20.157.130   internal-XXXX-XXXX.ap-southeast-1.elb.amazonaws.com   8889:31333/TCP,8000:32307/TCP   45h
deployment.apps/velociraptor      2/2     2            2           41h
replicaset.apps/velociraptor-6db4b5ff8d      2         2         2       26m
```

You will now need to set the Route53 DNS record to point the domain you specify during your config generation.
```
Route53 to point velociraptor.example.com to internal-XXXX-XXXX.ap-southeast-1.elb.amazonaws.com
``` 

When you view the logs of the pod, you should see these which indicate successful launching:
```
[INFO] 2019-11-20T02:06:33Z Starting Frontend. {"build_time":"2019-11-13T20:13:28+10:00","commit":"b4875f0","version":"0.3.6"}
[INFO] 2019-11-20T02:06:34Z Loaded 128 built in artifacts
[INFO] 2019-11-20T02:06:34Z Error increasing limit operation not permitted. This might work better as root.
[INFO] 2019-11-20T02:06:34Z Launched Prometheus monitoring server on 0.0.0.0:8003
[INFO] 2019-11-20T02:06:34Z Frontend is ready to handle client TLS requests at 0.0.0.0:8000
[INFO] 2019-11-20T02:06:34Z Starting hunt manager.
[INFO] 2019-11-20T02:06:34Z Launched gRPC API server on 0.0.0.0:8001
[INFO] 2019-11-20T02:06:34Z Starting Hunt Dispatcher Service.
[INFO] 2019-11-20T02:06:34Z Starting Stats Collector Service.
[INFO] 2019-11-20T02:06:34Z Starting Server Monitoring Service
[INFO] 2019-11-20T02:06:34Z Starting Server Artifact Runner Service
[INFO] 2019-11-20T02:06:34Z Collecting Server Event Artifact: Server.Monitor.Health/Prometheus
[INFO] 2019-11-20T02:06:34Z Starting Client Monitoring Service
[INFO] 2019-11-20T02:06:34Z Collecting Client Monitoring Artifact: Generic.Client.Stats
[INFO] 2019-11-20T02:06:34Z Collecting Client Monitoring Artifact: Windows.Events.ProcessCreation
[INFO] 2019-11-20T02:06:34Z GUI is ready to handle TLS requests {"listenAddr":"0.0.0.0:8889"}
[INFO] 2019-11-20T02:06:34Z Starting interrogation service.
[INFO] 2019-11-20T02:06:34Z Starting VFS writing service.
```

All done, enjoy using Velociraptor at https://velociraptor.example.com:8889
