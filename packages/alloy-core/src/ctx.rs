use crate::ports;

pub trait Ctx {
    fn age(&self) -> &dyn ports::Age;

    fn fs(&self) -> &dyn ports::FileSystem;

    fn gen_runner(&self) -> &dyn ports::GenRunner;
}
