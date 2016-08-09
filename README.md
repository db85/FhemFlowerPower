# Fhem Flower Power Modules
Fhem module to fetch data from Parrot Flower Power API

## How to use

1) You need a client_id and client_secret
https://apiflowerpower.parrot.com/api_access/signup

2) Define an api device in fhem
```
"define <name> FlowerPowerApi <username> <password> <client_id> <client_secret> <update_intervall_in_sec>" 
```
Example:
define MyFlowerPowerApi FlowerPowerApi user123 password123 abcd xyz 3600

3) Define a device for each flower
```
"define <name> FlowerPowerDevice <api_name> <location_identifier> <interval_in_sec>"
```
Example:
define MyFlower1 FlowerPowerDevice MyFlowerPowerApi qwertzu43234 3600

You will find the location identifier forach each flower in the api device readings

## How to upload data automatically to the cloud?

For that I use the following bridge from the parrot developers
https://github.com/Parrot-Developers/node-flower-bridge
