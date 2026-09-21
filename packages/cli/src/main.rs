use clap::Parser;

mod cli;
mod lib;

fn main() {
    cli::handle_args(cli::Args::parse());
}
