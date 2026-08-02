import sys
import os 
import pathlib
import json

this_file_dir = os.path.dirname(__file__)
if os.name not in ['nt', 'posix']:
    raise Exception('Unsupported platform: ' + os.name)

# Prefer the compiled bindings over the installed stub-only pyuipc package.
sys.path[:0] = [
    this_file_dir + '/modules/Release/bin',
    this_file_dir + '/modules/RelWithDebInfo/bin',
    this_file_dir + '/modules/releasedbg',
    this_file_dir + '/modules/release',
]

import pyuipc

def init():
    if pyuipc.__file__ is None:
        err_message = '''Python binding is not built.
        Please make a `Release` or `RelWithDebInfo` build with option `-DUIPC_BUILD_PYBIND=1` to enable python binding.'''
        raise Exception(err_message)
    
    # get module path
    module_path = pathlib.Path(pyuipc.__file__).absolute()
    module_dir = module_path.parent

    config = pyuipc.default_config()
    config['module_dir'] = str(module_dir)
    pyuipc.init(config)

init()

from pyuipc import *
__version__ = pyuipc.__version__
