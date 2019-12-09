FROM ubuntu:19.04

COPY ./velociraptor-v0.3.6-linux-amd64 /home/ubuntu/velociraptor

WORKDIR /home/ubuntu/

RUN chmod +x ./velociraptor

CMD ["/home/ubuntu/velociraptor", "--config", "/home/ubuntu/server.config.yaml", "frontend", "-v"]
