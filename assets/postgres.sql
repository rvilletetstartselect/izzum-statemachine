-- This file contains a fully normalized, indexed and functioning backend implementation 
-- for the izzum statemachine for a postgresql database (www.postgresql.org)

-- each table has extensive comments on what data they contain and what it means
-- and also on how to use them from the application code.


-- what should you do?
	-- define the machines in statemachine_machines.
	-- define the states for the machines in statemachine_states.
	-- define the transitions between states for the machines in statemachine_transitions
		-- this will also define the rules and commands for those transitions.
		-- read the definition for the statemachine via a join on statemachine_transitions and statemachine_states.
	-- add an entity to the persisten storage in statemachine_entities. 
		-- do this via application logic (see table comments).
		-- an entity_id is the unique id from your application specific domain model you wish to add stateful behaviour to.
		-- retrieve the current state for an entity in a machine.
		-- set the new current state for an entity in a machine.
	-- write history records for entities and their transitions in a machine in statemachine_history.
		-- do this via application logic (see table comments).


DROP TABLE IF EXISTS statemachine_history;
DROP TABLE IF EXISTS statemachine_entities;
DROP TABLE IF EXISTS statemachine_transitions;
DROP TABLE IF EXISTS statemachine_states;
DROP TABLE IF EXISTS statemachine_machines;
DROP SEQUENCE IF EXISTS s_statemachine_history_id;




-- machines
CREATE TABLE statemachine_machines (
	machine varchar NOT NULL, -- the machine name, for your reference and for a reference in the application code. It is a natural key.
	description text, -- optional: a descriptive text
	factory text -- optional: the fully qualified name of the factory to be instantiated (if you want to be able to use this dynamically)
);

COMMENT ON TABLE statemachine_machines IS 'the different statemachines used are defined here. 
A human readable description is used for documentation purposes.
changes in the name of a machine will be cascaded through the other tables.
The factory column contains the fully qualified class path to an instance of the AbstractFactory for creating a statemachine';
CREATE UNIQUE INDEX u_statemachine_machines_machine ON statemachine_machines (machine);
ALTER TABLE statemachine_machines ADD PRIMARY KEY (machine);



-- states
CREATE TABLE statemachine_states (
	machine varchar NOT NULL, -- a foreign key to the machine name.
	state varchar NOT NULL, -- a state for the machine. use lowercase and hyphen seperated. eg: my-state
	state_type varchar DEFAULT 'normal'::character varying NOT NULL, -- one of initial, normal or final
	description text -- optional: a descriptive text
);
COMMENT ON TABLE statemachine_states IS 'Valid states for a specific machine type.
Each statemachine MUST have ONE state of type "initial".
This is used to create the initial state if an entity is not yet represented in this system.
The implicit assumption is that a statemachine always has (and can only have) ONE initial state,
which is the entry point. The default name for this state is "new".
All states must be lowercase and use hyphens instead of spaces eg: my-state.
changes in the name of a state will be cascaded through the other tables';
CREATE UNIQUE INDEX u_statemachine_states_m_s ON statemachine_states (machine, state);
ALTER TABLE statemachine_states ADD CHECK ((state)::text = lower((state)::text));
ALTER TABLE statemachine_states ADD CHECK ((state_type)::text = ANY ((ARRAY['normal'::character varying, 'final'::character varying, 'initial'::character varying])::text[]));
ALTER TABLE statemachine_states ADD PRIMARY KEY (state, machine);
ALTER TABLE statemachine_states ADD FOREIGN KEY (machine) REFERENCES statemachine_machines (machine) ON DELETE NO ACTION ON UPDATE CASCADE;




--transitions
CREATE TABLE statemachine_transitions (
	machine varchar  NOT NULL, 
	state_from varchar  NOT NULL, -- the state this transition is from
	state_to varchar  NOT NULL, -- the state this transition is to
	rule varchar  DEFAULT '\izzum\rules\True'::character varying NOT NULL, -- the fully qualified name of a Rule class to instantiate
	command varchar  DEFAULT '\izzum\command\Null'::character varying NOT NULL, -- the fully qualified name of a Command class to instantiate
	priority int4 DEFAULT 1 NOT NULL, -- optional: can be used if you want your rules to be tried in a certain order. make sure to ORDER in your retrieval query.
	description text -- optional: a descriptive text
);
COMMENT ON TABLE statemachine_transitions IS 'define the transitions to be used per statemachine.
A rule is used to check a transition possibility (use a fully qualified classname). 
The default True rule always allows a transition. 
A command is used to execute the transition logic (use a fully qualified classname).
The default Null command does nothing.
Priority is only relevant for the unique combination of {machine, state_from} and 
has context in the preferred order of checking rules for the transition from a state,
since this allows you to check a higher priority rule first, followed by transition with a 
True rule if the first rule does not apply. 
Priority can be used to order the transitions for the statemachine.

All data for a statemachine can be retrieved via a join on this table and the statemachine_state table.
This should be done by an implementation of izzum\statemachine\loader\Loader.';
CREATE UNIQUE INDEX u_statemachine_transitions_m_sf_st ON statemachine_transitions (machine, state_from, state_to);
ALTER TABLE statemachine_transitions ADD PRIMARY KEY (machine, state_from, state_to);
ALTER TABLE statemachine_transitions ADD FOREIGN KEY (machine, state_from) REFERENCES statemachine_states (machine, state) ON DELETE NO ACTION ON UPDATE CASCADE;
ALTER TABLE statemachine_transitions ADD FOREIGN KEY (machine, state_to) REFERENCES statemachine_states (machine, state) ON DELETE NO ACTION ON UPDATE CASCADE;



-- entities. store current states coupled to an entity_id 
CREATE TABLE statemachine_entities (
	machine varchar NOT NULL,
	entity_id varchar(255) NOT NULL, -- the unique id of your application specific domain model (eg: an Order)
	state varchar NOT NULL, -- the current state
	changetime timestamp(6) DEFAULT now() NOT NULL -- when the current state was set
);
COMMENT ON TABLE statemachine_entities IS 'This table contains the current states for specific entities in machines. 
This makes it easy to look up a current state for an entity in a machine.
there can be only ONE entry per {entity_id, machine} tuple.
The actual state is stored here. Transition information will be stored in the
statemachine_history table, where the latest record should equal the actual state.
If there is no previous state (first transition), the state should default to the 
first state of the machine with type "initial".


The data that will be written to this table by a subclass of izzum\statemachine\persistence\Adapter specifically written for postgres. 
Entities should be explicitely added to the statemachine by application logic. 
This will be done in the method "add($context)" which should write the first entry for this entity: a "new" state.

After a transition, the new state will be set in this table and will overwrite the current value.
This will be done in the overriden method "processSetState($context, $state)".

The current state should be read from this table via the overriden method "processGetState($context)".

All entity_ids for a machine in a specific state should be retrieved from this table via the method "getEntityIds($machine, $state)".';
CREATE INDEX i_statemachine_entities_entity_id ON statemachine_entities (entity_id);
ALTER TABLE statemachine_entities ADD PRIMARY KEY (machine, entity_id);
ALTER TABLE statemachine_entities ADD FOREIGN KEY (machine, state) REFERENCES statemachine_states (machine, state) ON DELETE NO ACTION ON UPDATE CASCADE;




-- history. for accounting purposes. optional
CREATE SEQUENCE s_statemachine_history_id;
CREATE TABLE statemachine_history (
	id int4 DEFAULT nextval('s_statemachine_history_id'::regclass) NOT NULL, -- we use a surrogate key since we have no natural primary key
	machine varchar  NOT NULL,
	entity_id varchar NOT NULL,
	state_from varchar NOT NULL, -- the state from which the transition was done
	state_to varchar NOT NULL, -- the state to which the transition was done. the present current state
	changetime timestamp(6) DEFAULT now() NOT NULL, -- when the transition was made
	changetime_previous timestamp(6) DEFAULT now(), -- can be NULL, implying the creation time when the entity was added to the machine.
							-- there should be only one NULL value for all unique {machine,entity_id} tuples .
							-- In all other cases, it should be the time that was present on
							-- 'statemachine_entities.changetime' before the change to the new state.
	message text 	-- optional: this should only be set when there is an error thrown from the statemachine.
			-- both state_from and state_to will then be the same AND this field will be filled,
			-- preferably with json, to store both exception code and message.
			-- application code will then be able to display this.
			-- If/when state_to and state_from are the same AND this field is empty,
			-- it will mean a succesfull self transition has been made.
);
COMMENT ON TABLE statemachine_history IS 'Each transition made by a state machine should write a record in this table and 
this will provide the full history overview.
State_to should be equal to the the state of the last added {machine,entity_id} tuple in the statemachine_entities table.
Changetime contains the timestamp of the transition.
In case the changetime_previous is NULL this would mean that this is the entry point in 
the table: the creation of the stateful entitiy/addition to the statemachine.
The message column is used to store information about transition failures. 
A transition failure will occur when there is an exception during the transition phase, 
possibly thrown or generated from a command. 
This should result in one or multiple records in this table with the same state_from as state_to.
This is different from a self transition, since the message field will be filled with exception data. 
The message column could store json so we can use the exception code and message in this field.

Entities should be explicitely added to the statemachine by application logic. 
This will be done in a subclass of izzum\statemachine\persistence\Adapter. 
The logic will be implemented in the method "add($context)" for the first entry,
and in the method "processSetCurrentState($context, $state)" for all subsequent entries.';
CREATE INDEX i_statemachine_history_entity_id ON statemachine_history (entity_id);
ALTER TABLE statemachine_history ADD PRIMARY KEY (id);
ALTER TABLE statemachine_history ADD FOREIGN KEY (machine, state_from) REFERENCES statemachine_states (machine, state) ON DELETE NO ACTION ON UPDATE CASCADE;
ALTER TABLE statemachine_history ADD FOREIGN KEY (machine, state_to) REFERENCES statemachine_states (machine, state) ON DELETE NO ACTION ON UPDATE CASCADE;


