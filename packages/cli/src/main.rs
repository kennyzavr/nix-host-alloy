use clap::Parser;

mod cli;
mod ctx;
mod domain;
mod error;
mod infra;
mod services;

// TODO check age key pair files to existance
fn main() {
    cli::handle_args(cli::Args::parse());
}
