module callisto.compiler;

import std.file;
import std.path;
import std.array;
import std.stdio;
import std.format;
import std.algorithm;
import callisto.util;
import callisto.error;
import callisto.parser;
import callisto.language;

struct StructEntry {
	Type   type;
	string name;
	bool   array;
	size_t size;
	size_t offset;
}

struct Type {
	string        name;
	ulong         size;
	bool          isStruct;
	StructEntry[] structure;
	bool          hasInit;
	bool          hasDeinit;
}

struct Variable {
	string name;
	Type   type;
	uint   offset; // SP + offset to access
	bool   array;
	ulong  arraySize;

	size_t Size() => array? arraySize * type.size : type.size;
}

struct Global {
	string name;
	Type   type;
	bool   array;
	ulong  arraySize;
	void*  extra;

	size_t Size() => array? arraySize * type.size : type.size;
}

struct Constant {
	Node value;
}

struct Array {
	string[] values;
	Type     type;
	bool     global;
	void*    extra;

	size_t Size() => type.size * values.length;
}

class CompilerBackend {
	string     output;
	ulong      org;
	bool       orgSet;
	Compiler   compiler;
	bool       useDebug;
	bool       exportSymbols;
	string[]   link;
	bool       keepAssembly;
	string     os;
	string     defaultOS;
	Variable[] variables;
	Global[]   globals;
	Array[]    arrays;
	Type[]     types;

	abstract string[] GetVersions();
	abstract string[] FinalCommands();
	abstract long     MaxInt();
	abstract void     NewConst(string name, long value, ErrorInfo error);
	abstract string   DefaultHeader();
	abstract bool     HandleOption(string opt, ref string[] versions);

	abstract void BeginMain();

	abstract void Init();
	abstract void End();
	abstract void CompileWord(WordNode node);
	abstract void CompileInteger(IntegerNode node);
	abstract void CompileFuncDef(FuncDefNode node);
	abstract void CompileIf(IfNode node);
	abstract void CompileWhile(WhileNode node);
	abstract void CompileLet(LetNode node);
	abstract void CompileArray(ArrayNode node);
	abstract void CompileString(StringNode node);
	abstract void CompileStruct(StructNode node);
	abstract void CompileReturn(WordNode node);
	abstract void CompileConst(ConstNode node);
	abstract void CompileEnum(EnumNode node);
	abstract void CompileBreak(WordNode node);
	abstract void CompileContinue(WordNode node);
	abstract void CompileUnion(UnionNode node);
	abstract void CompileAlias(AliasNode node);
	abstract void CompileExtern(ExternNode node);
	abstract void CompileCall(WordNode node);
	abstract void CompileAddr(AddrNode node);
	abstract void CompileImplement(ImplementNode node);
	abstract void CompileSet(SetNode node);
	abstract void CompileTryCatch(TryCatchNode node);
	abstract void CompileThrow(WordNode node);

	final void Error(Char, A...)(ErrorInfo error, in Char[] fmt, A args) {
		ErrorBegin(error);
		stderr.writeln(format(fmt, args));
		PrintErrorLine(error);
		compiler.success = false;
	}

	final void Warn(Char, A...)(ErrorInfo error, in Char[] fmt, A args) {
		WarningBegin(error);
		stderr.writeln(format(fmt, args));
		PrintErrorLine(error);
	}

	final bool VariableExists(string name) => variables.any!(v => v.name == name);

	final Variable GetVariable(string name) {
		foreach (ref var ; variables) {
			if (var.name == name) {
				return var;
			}
		}

		assert(0);
	}

	final bool TypeExists(string name) => types.any!(v => v.name == name);

	final Type GetType(string name) {
		foreach (ref type ; types) {
			if (type.name == name) {
				return type;
			}
		}

		assert(0);
	}

	final void SetType(string name, Type ptype) {
		foreach (i, ref type ; types) {
			if (type.name == name) {
				types[i] = ptype;
				return;
			}
		}

		assert(0);
	}

	final bool GlobalExists(string name) => globals.any!(v => v.name == name);

	final Global GetGlobal(string name) {
		foreach (ref global ; globals) {
			if (global.name == name) {
				return global;
			}
		}

		assert(0);
	}

	final bool IsStructMember(string identifier) {
		string[] parts = identifier.split(".");

		if (parts.length < 2) return false;

		if (VariableExists(parts[0]))    return GetVariable(parts[0]).type.isStruct;
		else if (GlobalExists(parts[0])) return GetGlobal(parts[0]).type.isStruct;
		else                             return false;
	}

	final size_t GetStructOffset(Node node, string identifier) {
		string[] parts = identifier.split(".");

		StructEntry[] structure;

		if (VariableExists(parts[0])) {
			structure = GetVariable(parts[0]).type.structure;
		}
		else if (GlobalExists(parts[0])) {
			structure = GetGlobal(parts[0]).type.structure;
		}
		else {
			Error(node.error, "Structure '%s' doesn't exist");
		}

		parts = parts[1 .. $];

		size_t offset;

		while (parts.length > 1) {
			ptrdiff_t index = structure.countUntil!(a => a.name == parts[0]);

			if (index == -1) {
				Error(node.error, "Member '%s' doesn't exist", parts[0]);
			}
			if (!structure[index].type.isStruct) {
				Error(node.error, "Member '%s' is not a structure", parts[0]);
			}

			offset    += structure[index].offset;
			structure  = structure[index].type.structure;
			parts      = parts[1 .. $];
		}

		ptrdiff_t index = structure.countUntil!(a => a.name == parts[0]);

		if (index == -1) {
			Error(node.error, "Member '%s' doesn't exist", parts[0]);
		}

		offset += structure[index].offset;
		return offset;
	}

	final size_t GetStackSize() {
		// old
		//return variables.empty()? 0 : variables[0].offset + variables[0].type.size;

		size_t size;
		foreach (ref var ; variables) {
			size += var.Size();
		}

		return size;
	}
}

class CompilerError : Exception {
	this() {
		super("", "", 0);
	}
}

class Compiler {
	CompilerBackend backend;
	string[]        includeDirs;
	string[]        included;
	string          outFile;
	string[]        versions;
	bool            assemblyLines;
	bool            success = true;

	this() {
		
	}

	void CompileNode(Node inode) {
		switch (inode.type) {
			case NodeType.Word: {
				auto node = cast(WordNode) inode;

				switch (node.name) {
					case "return":   backend.CompileReturn(node);   break;
					case "continue": backend.CompileContinue(node); break;
					case "break":    backend.CompileBreak(node);    break;
					case "call":     backend.CompileCall(node);     break;
					case "throw":    backend.CompileThrow(node);    break;
					case "error":    backend.Error(node.error, "Error thrown by code"); break;
					default:         backend.CompileWord(node);
				}
				break;
			}
			case NodeType.Integer: backend.CompileInteger(cast(IntegerNode) inode); break;
			case NodeType.FuncDef: backend.CompileFuncDef(cast(FuncDefNode) inode); break;
			case NodeType.Include: {
				auto node  = cast(IncludeNode) inode;
				auto path  = format("%s/%s", dirName(node.error.file), node.path);

				if (!exists(path)) {
					bool found;
					
					foreach (ref ipath ; includeDirs) {
						path = format("%s/%s", ipath, node.path);

						if (exists(path)) {
							found = true;
							break;
						}
					}

					if (!found) {
						backend.Error(node.error, "Can't find file '%s'", node.path);
					}
				}

				if (included.canFind(path)) {
					break;
				}

				included ~= path;

				auto nodes = ParseFile(path);

				foreach (inode2 ; nodes) {
					CompileNode(inode2);
				}
				break;
			}
			case NodeType.Asm: {
				auto node       = cast(AsmNode) inode;
				backend.output ~= node.code;
				break;
			}
			case NodeType.If: backend.CompileIf(cast(IfNode) inode); break;
			case NodeType.While: {
				auto node = cast(WhileNode) inode;

				NodeType[] allowedTypes = [
					NodeType.Word, NodeType.Integer
				];

				foreach (ref inode2 ; node.condition) {
					if (!allowedTypes.canFind(inode2.type)) {
						backend.Error(
							inode2.error, "While conditions can't contain %s",
							inode2.type
						);
					}
				}

				backend.CompileWhile(node);
				break;
			}
			case NodeType.Let: backend.CompileLet(cast(LetNode) inode); break;
			case NodeType.Requires: {
				auto node = cast(RequiresNode) inode;

				if (!versions.canFind(node.ver)) {
					backend.Error(node.error, "Version '%s' required", node.ver);
				}
				break;
			}
			case NodeType.Array:     backend.CompileArray(cast(ArrayNode) inode); break;
			case NodeType.String:    backend.CompileString(cast(StringNode) inode); break;
			case NodeType.Struct:    backend.CompileStruct(cast(StructNode) inode); break;
			case NodeType.Const:     backend.CompileConst(cast(ConstNode) inode); break;
			case NodeType.Enum:      backend.CompileEnum(cast(EnumNode) inode); break;
			case NodeType.Union:     backend.CompileUnion(cast(UnionNode) inode); break;
			case NodeType.Alias:     backend.CompileAlias(cast(AliasNode) inode); break;
			case NodeType.Extern:    backend.CompileExtern(cast(ExternNode) inode); break;
			case NodeType.Addr:      backend.CompileAddr(cast(AddrNode) inode); break;
			case NodeType.Implement: backend.CompileImplement(cast(ImplementNode) inode); break;
			case NodeType.Set:       backend.CompileSet(cast(SetNode) inode); break;
			case NodeType.TryCatch:  backend.CompileTryCatch(cast(TryCatchNode) inode); break;
			default: {
				backend.Error(inode.error, "Unimplemented node '%s'", inode.type);
			}
		}

		if (assemblyLines) {
			//backend.output ~= "; " ~ inode.toString().replace("\n", "\n; ") ~ '\n';
			size_t line = backend.output.count!((ch) => ch == '\n');
			writefln(
				"%s:%d:%d - line %d, node %s", inode.error.file, inode.error.line + 1,
				inode.error.col + 1, line, inode.type
			);
		}
	}

	void Compile(Node[] nodes) {
		assert(backend !is null);

		backend.compiler = this;
		backend.Init();

		backend.NewConst("true",  backend.MaxInt(), ErrorInfo.init);
		backend.NewConst("false", 0, ErrorInfo.init);

		Node[] header;
		Node[] main;

		foreach (ref node ; nodes) {
			switch (node.type) {
				case NodeType.FuncDef:
				case NodeType.Include:
				case NodeType.Let:
				case NodeType.Enable:
				case NodeType.Requires:
				case NodeType.Struct:
				case NodeType.Const:
				case NodeType.Enum:
				case NodeType.Union:
				case NodeType.Alias:
				case NodeType.Extern:
				case NodeType.Implement: {
					header ~= node;
					break;
				}
				default: main ~= node;
			}
		}

		foreach (ref node ; header) {
			CompileNode(node);
		}

		backend.BeginMain();

		foreach (ref node ; main) {
			CompileNode(node);
		}

		backend.End();
	}
}
