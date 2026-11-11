# Setup do Benchmark (WSL Ubuntu)

O projeto foi montado para correr num setup wsl2 ubuntu, e aqui listado está o setup necessário para replicar o teste.

Para instalar os pacotes do Ubuntu:

```bash
sudo apt update
sudo apt install -y build-essential cmake pkg-config libssl-dev curl python3 golang-go openjdk-21-jdk
```

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
rustup toolchain install stable
rustup default stable
```

```bash
cargo install oha
```

Finalmente, para correr o teste:

```
bash scripts/run_benchmarks.sh
```

Os resultados ficam guardados numa pasta que é criada automaticamente com a data do teste.
