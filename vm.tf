resource "azurerm_virtual_network" "vnet_aula" {
    name                = "myVnet"
    address_space       = ["10.80.0.0/16"]
    location            = "eastus"
    resource_group_name = azurerm_resource_group.resource-group-es.name

    depends_on = [ azurerm_resource_group.resource-group-es ]
}

resource "azurerm_subnet" "snet" {
    name                 = "my-snet"
    resource_group_name  = azurerm_resource_group.resource-group-es.name
    virtual_network_name = azurerm_virtual_network.vnet_aula.name
    address_prefixes       = ["10.80.4.0/24"]

    depends_on = [ azurerm_resource_group.resource-group-es, azurerm_virtual_network.vnet_aula ]
}

resource "azurerm_public_ip" "public-ip" {
    name                         = "public-ip-vm"
    location                     = azurerm_resource_group.resource-group-es.location
    resource_group_name          = azurerm_resource_group.resource-group-es.name
    allocation_method            = "Static"
    idle_timeout_in_minutes = 30

    depends_on = [ azurerm_resource_group.resource-group-es ]
}

resource "azurerm_network_interface" "nic-es" {
    name                      = "nic"
    location                  = azurerm_resource_group.resource-group-es.location
    resource_group_name       = azurerm_resource_group.resource-group-es.name

    ip_configuration {
        name                          = "myNicConfigurationDB"
        subnet_id                     = azurerm_subnet.snet.id
        private_ip_address_allocation = "Static"
        private_ip_address            = "10.80.4.10"
        public_ip_address_id          = azurerm_public_ip.public-ip.id
    }

    depends_on = [ azurerm_resource_group.resource-group-es, azurerm_subnet.snet ]
}

resource "azurerm_network_interface_security_group_association" "nicsq_aula_db" {
    network_interface_id      = azurerm_network_interface.nic-es.id
    network_security_group_id = azurerm_network_security_group.sg-es.id

    depends_on = [ azurerm_network_interface.nic-es, azurerm_network_security_group.sg-es ]
}

data "azurerm_public_ip" "ip_aula_data_db" {
  name                = azurerm_public_ip.public-ip.name
  resource_group_name = azurerm_resource_group.resource-group-es.name
}


resource "azurerm_network_security_group" "sg-es" {
    name                = "security-group"
    location            = azurerm_resource_group.resource-group-es.location
    resource_group_name = azurerm_resource_group.resource-group-es.name

    security_rule {
        name                       = "SSH"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "HTTPInbound"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    depends_on = [ azurerm_resource_group.resource-group-es ]
}

resource "azurerm_storage_account" "storage_aula_db" {
    name                        = "storageauladb"
    resource_group_name         = azurerm_resource_group.resource-group-es.name
    location                    = azurerm_resource_group.resource-group-es.location
    account_tier                = "Standard"
    account_replication_type    = "LRS"

    tags = {
        environment = "aula infra"
    }

    depends_on = [ azurerm_resource_group.resource-group-es ]
}

resource "azurerm_linux_virtual_machine" "vm-db-mysql" {
    name                  = "vm-db"
    location              = azurerm_resource_group.resource-group-es.location
    resource_group_name   = azurerm_resource_group.resource-group-es.name
    network_interface_ids = [azurerm_network_interface.nic-es.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "myOsDBDisk"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "myvmdb"
    admin_username = "appadm"
    admin_password = "passWord123!"
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.storage_aula_db.primary_blob_endpoint
    }


    depends_on = [ azurerm_resource_group.resource-group-es, azurerm_network_interface.nic-es, azurerm_storage_account.storage_aula_db, azurerm_public_ip.public-ip ]
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vm-db-mysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = "appadm"
            password = "passWord123!"
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        source = "mysql"
        destination = "/home/appadm"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = "appadm"
            password = "passWord123!"
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/appadm/mysql/script/user.sql",
            "sudo mysql < /home/appadm/mysql/script/schema.sql",
            "sudo mysql < /home/appadm/mysql/script/data.sql",
            "sudo cp -f /home/appadm/mysql/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}