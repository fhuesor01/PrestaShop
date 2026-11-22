# -*- mode: ruby -*-
# vi: set ft=ruby :

# --- direcciones ip
IP_PS = "192.168.56.10"   # feliprestashop (ip fija a la que apunta el dominio)

# token de duckdns--> se lee de la variable de entorno, para asi no comprometer nuestro token
DUCKDNS_TOKEN = ENV.fetch("DUCKDNS_TOKEN", "")

# el resto de variables (bd, dominio, prestashop...) estan en scripts/.env,
# y son los propios scripts los que lo cargan desde la carpeta compartida /vagrant

Vagrant.configure("2") do |config|

  # box oficial de Debian 12 (Bookworm)
  config.vm.box = "debian/bookworm64"

  # --- maquina prestashop
  config.vm.define "feliprestashop" do |ps|
    # con esta linea estamos identificando el nombre de la maquina
    ps.vm.hostname = "feliprestashop"
    # con esta linea estamos creando la interfaz de red privada con la ip fija (equivalente a la ip elastica de aws)
    ps.vm.network "private_network", ip: IP_PS

    # aqui estamos especificando a Vbox, las caracteristicas de la maquina-->
    # nombre, RAM y CPUs
    ps.vm.provider "virtualbox" do |vb|
      vb.name   = "feliprestashop"
      vb.memory = 2048
      vb.cpus   = 2
    end

    # aqui indicamos la ruta del script de provisionamiento de la pila lamp
    ps.vm.provision "shell", name: "lamp", path: "scripts/p-scriptlamp.sh"

    # aqui indicamos la ruta y el token que vamos a usar para la parte del certificado Let's Encrypt y activar el https
    # para este tendremos que haber previamente ejecutado en nuestro cmd ($env:DUCKDNS_TOKEN = "nuestro-token-duckdns"), si no tenemos configurada esta variable
    # de entorno no se ejecutara este script de aprovisionamiento, para poder hacerlo posteriormente
    ps.vm.provision "shell", name: "letsencrypt", path: "scripts/p-scriptletsencrypt.sh", env: {
      "DUCKDNS_TOKEN" => DUCKDNS_TOKEN
    }, run: DUCKDNS_TOKEN.empty? ? "never" : "once"

    # este no se ejecuta con el vagrant up (run: "never"), lo lanzamos nosotros con (vagrant provision --provision-with prestashop)
    # despues de comprobar con phppsinfo que cumplimos los requisitos, ya que este script lo borra al acabar
    ps.vm.provision "shell", name: "prestashop", path: "scripts/p-scriptprestashop.sh", run: "never"
  end
end
