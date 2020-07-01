# safe-transit

![](https://i.f1ssi0n.com/CollectivePollutedSturgeon.png)

safe-transit is a tcp relay. You run the endpoint app locally which connects to a relay on a server which clients can then connect to. (a fun side effect of this is that you dont need to port forward your app).

When the relay recieves new clients it starts forwarding that data to the endpoint. Once the endpoint knows of new clients it can open a connection with the application over loopback and starts sending data it recieves back to the relay.
If either side knows that a client/loopback has gone missing they inform the other so prevent dead weight on the relay channel. 
If the relay or endpoint goes down at any point it may be in an invalid state so all connections are closed and they start over trying to connect.