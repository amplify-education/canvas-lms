Note
====

The changes in this fork enables running canvas on a mac machine just with docker and no virtualbox.
In some machines where the user can not turn off the firewall they wont be able to modify some network files that may be
required for setting up canvas properly in a virtualbox using dinghy tool.

To make sure your application has enough memory, increase the memory allocated to docker to a little more than 8 gb.
(Recommend 12gb). This would mean that you will need to have a machine that has atleast 16 gb of system memory to run
Canvas LMS locally

Canvas LMS
======

Canvas is a modern, open-source [LMS](https://en.wikipedia.org/wiki/Learning_management_system)
developed and maintained by [Instructure Inc.](https://www.instructure.com/) It is released under the
AGPLv3 license for use by anyone interested in learning more about or using
learning management systems.

[Please see our main wiki page for more information](http://github.com/instructure/canvas-lms/wiki)

Installation
=======

Detailed instructions for installation and configuration of Canvas are provided
on our wiki.

 * [Quick Start](http://github.com/instructure/canvas-lms/wiki/Quick-Start)
 * [Production Start](http://github.com/instructure/canvas-lms/wiki/Production-Start)
